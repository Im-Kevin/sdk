// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/resolver/flow_analysis_visitor.dart';
import 'package:analyzer/src/dart/resolver/invocation_inference_helper.dart';
import 'package:analyzer/src/dart/resolver/resolution_result.dart';
import 'package:analyzer/src/dart/resolver/type_property_resolver.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/generated/element_type_provider.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer/src/generated/type_system.dart';
import 'package:analyzer/src/task/strong/checker.dart';
import 'package:meta/meta.dart';

/// Helper for resolving [AssignmentExpression]s.
class AssignmentExpressionResolver {
  final ResolverVisitor _resolver;
  final FlowAnalysisHelper _flowAnalysis;
  final ElementTypeProvider _elementTypeProvider;
  final TypePropertyResolver _typePropertyResolver;
  final InvocationInferenceHelper _inferenceHelper;

  AssignmentExpressionResolver({
    @required ResolverVisitor resolver,
    @required FlowAnalysisHelper flowAnalysis,
    @required ElementTypeProvider elementTypeProvider,
  })  : _resolver = resolver,
        _flowAnalysis = flowAnalysis,
        _elementTypeProvider = elementTypeProvider,
        _typePropertyResolver = resolver.typePropertyResolver,
        _inferenceHelper = resolver.inferenceHelper;

  ErrorReporter get _errorReporter => _resolver.errorReporter;

  bool get _isNonNullableByDefault => _typeSystem.isNonNullableByDefault;

  TypeProvider get _typeProvider => _resolver.typeProvider;

  TypeSystemImpl get _typeSystem => _resolver.typeSystem;

  void resolve(AssignmentExpressionImpl node) {
    var left = node.leftHandSide;
    var right = node.rightHandSide;

    left?.accept(_resolver);
    left = node.leftHandSide;

    var leftLocalVariable = _flowAnalysis?.assignmentExpression(node);

    TokenType operator = node.operator.type;
    if (operator == TokenType.EQ ||
        operator == TokenType.QUESTION_QUESTION_EQ) {
      InferenceContext.setType(right, left.staticType);
    }

    right?.accept(_resolver);
    right = node.rightHandSide;

    _resolve1(node);
    _resolve2(node);

    _flowAnalysis?.assignmentExpression_afterRight(
        node,
        leftLocalVariable,
        operator == TokenType.QUESTION_QUESTION_EQ
            ? node.rightHandSide.staticType
            : node.staticType);
  }

  void _resolve1(AssignmentExpressionImpl node) {
    Token operator = node.operator;
    TokenType operatorType = operator.type;
    Expression leftHandSide = node.leftHandSide;
    DartType staticType = _getStaticType1(leftHandSide, read: true);

    // For any compound assignments to a void or nullable variable, report it.
    // Example: `y += voidFn()`, not allowed.
    if (operatorType != TokenType.EQ) {
      if (staticType != null && staticType.isVoid) {
        _errorReporter.reportErrorForToken(
          StaticWarningCode.USE_OF_VOID_RESULT,
          operator,
        );
        return;
      }
    }

    if (operatorType != TokenType.AMPERSAND_AMPERSAND_EQ &&
        operatorType != TokenType.BAR_BAR_EQ &&
        operatorType != TokenType.EQ &&
        operatorType != TokenType.QUESTION_QUESTION_EQ) {
      operatorType = operatorFromCompoundAssignment(operatorType);
      if (leftHandSide != null) {
        String methodName = operatorType.lexeme;
        // TODO(brianwilkerson) Change the [methodNameNode] from the left hand
        //  side to the operator.
        var result = _typePropertyResolver.resolve(
          receiver: leftHandSide,
          receiverType: staticType,
          name: methodName,
          receiverErrorNode: leftHandSide,
          nameErrorNode: leftHandSide,
        );
        node.staticElement = result.getter;
        if (_shouldReportInvalidMember(staticType, result)) {
          _errorReporter.reportErrorForToken(
            StaticTypeWarningCode.UNDEFINED_OPERATOR,
            operator,
            [methodName, staticType],
          );
        }
      }
    }
  }

  /**
   * Return `true` if we should report an error for the lookup [result] on
   * the [type].
   *
   * TODO(scheglov) this is duplicate
   */
  bool _shouldReportInvalidMember(DartType type, ResolutionResult result) {
    if (result.isNone && type != null && !type.isDynamic) {
      if (_typeSystem.isNonNullableByDefault &&
          _typeSystem.isPotentiallyNullable(type)) {
        return false;
      }
      return true;
    }
    return false;
  }

  /**
   * Return the static type of the given [expression] that is to be used for
   * type analysis.
   *
   * TODO(scheglov) this is duplicate
   */
  DartType _getStaticType1(Expression expression, {bool read = false}) {
    if (expression is NullLiteral) {
      return _typeProvider.nullType;
    }
    DartType type = read
        ? getReadType(expression, elementTypeProvider: _elementTypeProvider)
        : expression.staticType;
    return _resolveTypeParameter(type);
  }

  /**
   * If the given [type] is a type parameter, resolve it to the type that should
   * be used when looking up members. Otherwise, return the original type.
   *
   * TODO(scheglov) this is duplicate
   */
  DartType _resolveTypeParameter(DartType type) =>
      type?.resolveToBound(_typeProvider.objectType);

  void _resolve2(AssignmentExpressionImpl node) {
    TokenType operator = node.operator.type;
    if (operator == TokenType.EQ) {
      Expression rightHandSide = node.rightHandSide;
      DartType staticType = _getStaticType2(rightHandSide);
      _inferenceHelper.recordStaticType(node, staticType);
    } else if (operator == TokenType.QUESTION_QUESTION_EQ) {
      if (_isNonNullableByDefault) {
        // The static type of a compound assignment using ??= with NNBD is the
        // least upper bound of the static types of the LHS and RHS after
        // promoting the LHS/ to non-null (as we know its value will not be used
        // if null)
        _analyzeLeastUpperBoundTypes(
            node,
            _typeSystem.promoteToNonNull(
                _getExpressionType(node.leftHandSide, read: true)),
            _getExpressionType(node.rightHandSide, read: true));
      } else {
        // The static type of a compound assignment using ??= before NNBD is the
        // least upper bound of the static types of the LHS and RHS.
        _analyzeLeastUpperBound(node, node.leftHandSide, node.rightHandSide,
            read: true);
      }
    } else if (operator == TokenType.AMPERSAND_AMPERSAND_EQ ||
        operator == TokenType.BAR_BAR_EQ) {
      _inferenceHelper.recordStaticType(
          node, _nonNullable(_typeProvider.boolType));
    } else {
      var operatorElement = node.staticElement;
      var type =
          _elementTypeProvider.safeExecutableReturnType(operatorElement) ??
              DynamicTypeImpl.instance;
      type = _typeSystem.refineBinaryExpressionType(
        _getStaticType2(node.leftHandSide, read: true),
        operator,
        node.rightHandSide.staticType,
        type,
      );
      _inferenceHelper.recordStaticType(node, type);

      var leftWriteType = _getStaticType2(node.leftHandSide);
      if (!_typeSystem.isAssignableTo(type, leftWriteType)) {
        _resolver.errorReporter.reportErrorForNode(
          StaticTypeWarningCode.INVALID_ASSIGNMENT,
          node.rightHandSide,
          [type, leftWriteType],
        );
      }
    }
    _resolver.nullShortingTermination(node);
  }

  /// Return the non-nullable variant of the [type] if NNBD is enabled, otherwise
  /// return the type itself.
  ///
  /// TODO(scheglov) this is duplicate
  DartType _nonNullable(DartType type) {
    if (_isNonNullableByDefault) {
      return _typeSystem.promoteToNonNull(type);
    }
    return type;
  }

  /**
   * Set the static type of [node] to be the least upper bound of the static
   * types of subexpressions [expr1] and [expr2].
   *
   * TODO(scheglov) this is duplicate
   */
  void _analyzeLeastUpperBound(
      Expression node, Expression expr1, Expression expr2,
      {bool read = false}) {
    DartType staticType1 = _getExpressionType(expr1, read: read);
    DartType staticType2 = _getExpressionType(expr2, read: read);

    _analyzeLeastUpperBoundTypes(node, staticType1, staticType2);
  }

  /**
   * Gets the definite type of expression, which can be used in cases where
   * the most precise type is desired, for example computing the least upper
   * bound.
   *
   * See [getExpressionType] for more information. Without strong mode, this is
   * equivalent to [_getStaticType].
   *
   * TODO(scheglov) this is duplicate
   */
  DartType _getExpressionType(Expression expr, {bool read = false}) =>
      getExpressionType(expr, _typeSystem, _typeProvider,
          read: read, elementTypeProvider: _elementTypeProvider);

  /**
   * Set the static type of [node] to be the least upper bound of the static
   * types [staticType1] and [staticType2].
   *
   * TODO(scheglov) this is duplicate
   */
  void _analyzeLeastUpperBoundTypes(
      Expression node, DartType staticType1, DartType staticType2) {
    if (staticType1 == null) {
      // TODO(brianwilkerson) Determine whether this can still happen.
      staticType1 = DynamicTypeImpl.instance;
    }

    if (staticType2 == null) {
      // TODO(brianwilkerson) Determine whether this can still happen.
      staticType2 = DynamicTypeImpl.instance;
    }

    DartType staticType =
        _typeSystem.getLeastUpperBound(staticType1, staticType2) ??
            DynamicTypeImpl.instance;

    staticType = _resolver.toLegacyTypeIfOptOut(staticType);

    _inferenceHelper.recordStaticType(node, staticType);
  }

  /**
   * Return the static type of the given [expression].
   *
   * TODO(scheglov) this is duplicate
   */
  DartType _getStaticType2(Expression expression, {bool read = false}) {
    DartType type;
    if (read) {
      type = getReadType(expression, elementTypeProvider: _elementTypeProvider);
    } else {
      if (expression is SimpleIdentifier && expression.inSetterContext()) {
        var element = expression.staticElement;
        if (element is PromotableElement) {
          // We're writing to the element so ignore promotions.
          type = _elementTypeProvider.getVariableType(element);
        } else {
          type = expression.staticType;
        }
      } else {
        type = expression.staticType;
      }
    }
    if (type == null) {
      // TODO(brianwilkerson) Determine the conditions for which the static type
      // is null.
      return DynamicTypeImpl.instance;
    }
    return type;
  }
}
