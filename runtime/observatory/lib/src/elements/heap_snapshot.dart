// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:html';
import 'dart:math' as Math;
import 'package:observatory/models.dart' as M;
import 'package:observatory/src/elements/class_ref.dart';
import 'package:observatory/src/elements/containers/virtual_tree.dart';
import 'package:observatory/src/elements/helpers/any_ref.dart';
import 'package:observatory/src/elements/helpers/nav_bar.dart';
import 'package:observatory/src/elements/helpers/nav_menu.dart';
import 'package:observatory/src/elements/helpers/rendering_scheduler.dart';
import 'package:observatory/src/elements/helpers/tag.dart';
import 'package:observatory/src/elements/helpers/uris.dart';
import 'package:observatory/src/elements/nav/isolate_menu.dart';
import 'package:observatory/src/elements/nav/notify.dart';
import 'package:observatory/src/elements/nav/refresh.dart';
import 'package:observatory/src/elements/nav/top_menu.dart';
import 'package:observatory/src/elements/nav/vm_menu.dart';
import 'package:observatory/utils.dart';

enum HeapSnapshotTreeMode {
  dominatorTree,
  mergedDominatorTree,
  ownershipTable,
  groupByClass
}

class HeapSnapshotElement extends CustomElement implements Renderable {
  static const tag =
      const Tag<HeapSnapshotElement>('heap-snapshot', dependencies: const [
    ClassRefElement.tag,
    NavTopMenuElement.tag,
    NavVMMenuElement.tag,
    NavIsolateMenuElement.tag,
    NavRefreshElement.tag,
    NavNotifyElement.tag,
    VirtualTreeElement.tag,
  ]);

  RenderingScheduler<HeapSnapshotElement> _r;

  Stream<RenderedEvent<HeapSnapshotElement>> get onRendered => _r.onRendered;

  M.VM _vm;
  M.IsolateRef _isolate;
  M.EventRepository _events;
  M.NotificationRepository _notifications;
  M.HeapSnapshotRepository _snapshots;
  M.ObjectRepository _objects;
  M.HeapSnapshot _snapshot;
  Stream<M.HeapSnapshotLoadingProgressEvent> _progressStream;
  M.HeapSnapshotLoadingProgress _progress;
  M.HeapSnapshotRoots _roots = M.HeapSnapshotRoots.user;
  HeapSnapshotTreeMode _mode = HeapSnapshotTreeMode.dominatorTree;

  M.IsolateRef get isolate => _isolate;
  M.NotificationRepository get notifications => _notifications;
  M.HeapSnapshotRepository get profiles => _snapshots;
  M.VMRef get vm => _vm;

  factory HeapSnapshotElement(
      M.VM vm,
      M.IsolateRef isolate,
      M.EventRepository events,
      M.NotificationRepository notifications,
      M.HeapSnapshotRepository snapshots,
      M.ObjectRepository objects,
      {RenderingQueue queue}) {
    assert(vm != null);
    assert(isolate != null);
    assert(events != null);
    assert(notifications != null);
    assert(snapshots != null);
    assert(objects != null);
    HeapSnapshotElement e = new HeapSnapshotElement.created();
    e._r = new RenderingScheduler<HeapSnapshotElement>(e, queue: queue);
    e._vm = vm;
    e._isolate = isolate;
    e._events = events;
    e._notifications = notifications;
    e._snapshots = snapshots;
    e._objects = objects;
    return e;
  }

  HeapSnapshotElement.created() : super.created(tag);

  @override
  attached() {
    super.attached();
    _r.enable();
    _refresh();
  }

  @override
  detached() {
    super.detached();
    _r.disable(notify: true);
    children = <Element>[];
  }

  void render() {
    final content = <Element>[
      navBar(<Element>[
        new NavTopMenuElement(queue: _r.queue).element,
        new NavVMMenuElement(_vm, _events, queue: _r.queue).element,
        new NavIsolateMenuElement(_isolate, _events, queue: _r.queue).element,
        navMenu('heap snapshot'),
        (new NavRefreshElement(queue: _r.queue)
              ..disabled = M.isHeapSnapshotProgressRunning(_progress?.status)
              ..onRefresh.listen((e) {
                _refresh();
              }))
            .element,
        new NavNotifyElement(_notifications, queue: _r.queue).element
      ]),
    ];
    if (_progress == null) {
      children = content;
      return;
    }
    switch (_progress.status) {
      case M.HeapSnapshotLoadingStatus.fetching:
        content.addAll(_createStatusMessage('Fetching snapshot from VM...',
            description: _progress.stepDescription,
            progress: _progress.progress));
        break;
      case M.HeapSnapshotLoadingStatus.loading:
        content.addAll(_createStatusMessage('Loading snapshot...',
            description: _progress.stepDescription,
            progress: _progress.progress));
        break;
      case M.HeapSnapshotLoadingStatus.loaded:
        content.addAll(_createReport());
        break;
    }
    children = content;
  }

  Future _refresh() async {
    _progress = null;
    _progressStream = _snapshots.get(isolate, roots: _roots, gc: true);
    _r.dirty();
    _progressStream.listen((e) {
      _progress = e.progress;
      _r.dirty();
    });
    _progress = (await _progressStream.first).progress;
    _r.dirty();
    if (M.isHeapSnapshotProgressRunning(_progress.status)) {
      _progress = (await _progressStream.last).progress;
      _snapshot = _progress.snapshot;
      _r.dirty();
    }
  }

  static List<Element> _createStatusMessage(String message,
      {String description: '', double progress: 0.0}) {
    return [
      new DivElement()
        ..classes = ['content-centered-big']
        ..children = <Element>[
          new DivElement()
            ..classes = ['statusBox', 'shadow', 'center']
            ..children = <Element>[
              new DivElement()
                ..classes = ['statusMessage']
                ..text = message,
              new DivElement()
                ..classes = ['statusDescription']
                ..text = description,
              new DivElement()
                ..style.background = '#0489c3'
                ..style.width = '$progress%'
                ..style.height = '15px'
                ..style.borderRadius = '4px'
            ]
        ]
    ];
  }

  VirtualTreeElement _tree;

  List<Element> _createReport() {
    var report = <HtmlElement>[
      new DivElement()
        ..classes = ['content-centered-big']
        ..children = <Element>[
          new DivElement()
            ..classes = ['memberList']
            ..children = <Element>[
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'Refreshed ',
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = Utils.formatDateTime(_snapshot.timestamp)
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'Objects ',
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = '${_snapshot.objects}'
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'References ',
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = '${_snapshot.references}'
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'Size ',
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = Utils.formatSize(_snapshot.size)
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'Roots ',
                  new DivElement()
                    ..classes = ['memberName']
                    ..children = _createRootsSelect()
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'Analysis ',
                  new DivElement()
                    ..classes = ['memberName']
                    ..children = _createModeSelect()
                ]
            ]
        ],
    ];
    switch (_mode) {
      case HeapSnapshotTreeMode.dominatorTree:
        _tree = new VirtualTreeElement(
            _createDominator, _updateDominator, _getChildrenDominator,
            items: _getChildrenDominator(_snapshot.dominatorTree),
            queue: _r.queue);
        _tree.expand(_snapshot.dominatorTree);
        final text = 'In a heap dominator tree, an object X is a parent of '
            'object Y if every path from the root to Y goes through '
            'X. This allows you to find "choke points" that are '
            'holding onto a lot of memory. If an object becomes '
            'garbage, all its children in the dominator tree become '
            'garbage as well.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTree:
        _tree = new VirtualTreeElement(_createMergedDominator,
            _updateMergedDominator, _getChildrenMergedDominator,
            items: _getChildrenMergedDominator(_snapshot.mergedDominatorTree),
            queue: _r.queue);
        _tree.expand(_snapshot.mergedDominatorTree);
        final text = 'A heap dominator tree, where siblings with the same class'
            ' have been merged into a single node.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.ownershipTable:
        final items = _snapshot.ownershipClasses.toList();
        items.sort((a, b) => b.size - a.size);
        _tree = new VirtualTreeElement(_createOwnershipClass,
            _updateOwnershipClass, _getChildrenOwnershipClass,
            items: items, queue: _r.queue);
        _tree.expand(_snapshot.dominatorTree);
        final text = 'An object X is said to "own" object Y if X is the only '
            'object that references Y, or X owns the only object that '
            'references Y. In particular, objects "own" the space of any '
            'unshared lists or maps they reference.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.groupByClass:
        final items = _snapshot.classReferences.toList();
        items.sort((a, b) => b.shallowSize - a.shallowSize);
        _tree = new VirtualTreeElement(
            _createGroup, _updateGroup, _getChildrenGroup,
            items: items, queue: _r.queue);
        _tree.expand(_snapshot.dominatorTree);
        report.add(_tree.element);
        break;
      default:
        break;
    }
    return report;
  }

  static HtmlElement _createDominator(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size',
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap being retained',
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createMergedDominator(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size',
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap being retained',
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createGroup(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['size']
          ..title = 'shallow size',
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()
          ..classes = ['count']
          ..title = 'shallow size',
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createOwnershipClass(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['size']
          ..title = 'owned size',
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap owned',
        new SpanElement()..classes = ['name']
      ];
  }

  static const int kMaxChildren = 100;
  static const int kMinRetainedSize = 4096;

  static Iterable _getChildrenDominator(nodeDynamic) {
    M.HeapSnapshotDominatorNode node = nodeDynamic;
    final list = node.children.toList();
    list.sort((a, b) => b.retainedSize - a.retainedSize);
    return list
        .where((child) => child.retainedSize >= kMinRetainedSize)
        .take(kMaxChildren);
  }

  static Iterable _getChildrenMergedDominator(nodeDynamic) {
    M.HeapSnapshotMergedDominatorNode node = nodeDynamic;
    final list = node.children.toList();
    list.sort((a, b) => b.retainedSize - a.retainedSize);
    return list
        .where((child) => child.retainedSize >= kMinRetainedSize)
        .take(kMaxChildren);
  }

  static Iterable _getChildrenGroup(item) {
    if (item is M.HeapSnapshotClassReferences) {
      if (item.inbounds.isNotEmpty || item.outbounds.isNotEmpty) {
        return [item.inbounds, item.outbounds];
      }
    } else if (item is Iterable) {
      return item.toList()..sort((a, b) => b.shallowSize - a.shallowSize);
    }
    return const [];
  }

  static Iterable _getChildrenOwnershipClass(item) {
    return const [];
  }

  void _updateDominator(HtmlElement element, nodeDynamic, int depth) {
    M.HeapSnapshotDominatorNode node = nodeDynamic;
    element.children[0].text = Utils.formatSize(node.retainedSize);
    _updateLines(element.children[1].children, depth);
    if (_getChildrenDominator(node).isNotEmpty) {
      element.children[2].text = _tree.isExpanded(node) ? '▼' : '►';
    } else {
      element.children[2].text = '';
    }
    element.children[3].text =
        Utils.formatPercentNormalized(node.retainedSize * 1.0 / _snapshot.size);
    final wrapper = new SpanElement()
      ..classes = ['name']
      ..text = 'Loading...';
    element.children[4] = wrapper;
    if (node.isStack) {
      wrapper
        ..text = ''
        ..children = <Element>[
          new AnchorElement(href: Uris.debugger(isolate))..text = 'stack frames'
        ];
    } else {
      node.object.then((object) {
        wrapper
          ..text = ''
          ..children = <Element>[
            anyRef(_isolate, object, _objects,
                queue: _r.queue, expandable: false)
          ];
      });
    }
  }

  void _updateMergedDominator(HtmlElement element, nodeDynamic, int depth) {
    M.HeapSnapshotMergedDominatorNode node = nodeDynamic;
    element.children[0].text = Utils.formatSize(node.retainedSize);
    _updateLines(element.children[1].children, depth);
    if (_getChildrenMergedDominator(node).isNotEmpty) {
      element.children[2].text = _tree.isExpanded(node) ? '▼' : '►';
    } else {
      element.children[2].text = '';
    }
    element.children[3].text =
        Utils.formatPercentNormalized(node.retainedSize * 1.0 / _snapshot.size);
    final wrapper = new SpanElement()
      ..classes = ['name']
      ..text = 'Loading...';
    element.children[4] = wrapper;
    if (node.isStack) {
      wrapper
        ..text = ''
        ..children = <Element>[
          new AnchorElement(href: Uris.debugger(isolate))..text = 'stack frames'
        ];
    } else {
      node.klass.then((klass) {
        wrapper
          ..text = ''
          ..children = <Element>[
            new SpanElement()..text = '${node.instanceCount} instances of ',
            anyRef(_isolate, klass, _objects,
                queue: _r.queue, expandable: false)
          ];
      });
    }
  }

  void _updateGroup(HtmlElement element, item, int depth) {
    _updateLines(element.children[1].children, depth);
    if (item is M.HeapSnapshotClassReferences) {
      element.children[0].text = Utils.formatSize(item.shallowSize);
      element.children[2].text = _tree.isExpanded(item) ? '▼' : '►';
      element.children[3].text = '${item.instances} instances of ';
      element.children[4] =
          (new ClassRefElement(_isolate, item.clazz, queue: _r.queue)
                ..classes = ['name'])
              .element;
    } else if (item is Iterable) {
      element.children[0].text = '';
      if (item.isNotEmpty) {
        element.children[2].text = _tree.isExpanded(item) ? '▼' : '►';
      } else {
        element.children[2].text = '';
      }
      element.children[3].text = '';
      int references = 0;
      for (var referenceGroup in item) {
        references += referenceGroup.count;
      }
      if (item is Iterable<M.HeapSnapshotClassInbound>) {
        element.children[4] = new SpanElement()
          ..classes = ['name']
          ..text = '$references incoming references';
      } else {
        element.children[4] = new SpanElement()
          ..classes = ['name']
          ..text = '$references outgoing references';
      }
    } else {
      element.children[0].text = '';
      element.children[2].text = '';
      element.children[3].text = '';
      element.children[4] = new SpanElement()..classes = ['name'];
      if (item is M.HeapSnapshotClassInbound) {
        element.children[3].text =
            '${item.count} references from instances of ';
        element.children[4].children = <Element>[
          new ClassRefElement(_isolate, item.source, queue: _r.queue).element
        ];
      } else if (item is M.HeapSnapshotClassOutbound) {
        element.children[3]..text = '${item.count} references to instances of ';
        element.children[4].children = <Element>[
          new ClassRefElement(_isolate, item.target, queue: _r.queue).element
        ];
      }
    }
  }

  void _updateOwnershipClass(HtmlElement element, item, int depth) {
    _updateLines(element.children[1].children, depth);
    element.children[0].text = Utils.formatSize(item.size);
    element.children[1].text =
        Utils.formatPercentNormalized(item.size * 1.0 / _snapshot.size);
    element.children[2] = new SpanElement()
      ..classes = ['name']
      ..children = <Element>[
        new SpanElement()..text = ' instances of ',
        (new ClassRefElement(_isolate, item.clazz, queue: _r.queue)
              ..classes = ['name'])
            .element
      ];
  }

  static _updateLines(List<Element> lines, int n) {
    n = Math.max(0, n);
    while (lines.length > n) {
      lines.removeLast();
    }
    while (lines.length < n) {
      lines.add(new SpanElement());
    }
  }

  static String rootsToString(M.HeapSnapshotRoots roots) {
    switch (roots) {
      case M.HeapSnapshotRoots.user:
        return 'User';
      case M.HeapSnapshotRoots.vm:
        return 'VM';
    }
    throw new Exception('Unknown HeapSnapshotRoots');
  }

  List<Element> _createRootsSelect() {
    var s;
    return [
      s = new SelectElement()
        ..classes = ['roots-select']
        ..value = rootsToString(_roots)
        ..children = M.HeapSnapshotRoots.values.map((roots) {
          return new OptionElement(
              value: rootsToString(roots), selected: _roots == roots)
            ..text = rootsToString(roots);
        }).toList(growable: false)
        ..onChange.listen((_) {
          _roots = M.HeapSnapshotRoots.values[s.selectedIndex];
          _refresh();
        })
    ];
  }

  static String modeToString(HeapSnapshotTreeMode mode) {
    switch (mode) {
      case HeapSnapshotTreeMode.dominatorTree:
        return 'Dominator tree';
      case HeapSnapshotTreeMode.mergedDominatorTree:
        return 'Dominator tree (merged siblings by class)';
      case HeapSnapshotTreeMode.ownershipTable:
        return 'Ownership table';
      case HeapSnapshotTreeMode.groupByClass:
        return 'Group by class';
    }
    throw new Exception('Unknown HeapSnapshotTreeMode');
  }

  List<Element> _createModeSelect() {
    var s;
    return [
      s = new SelectElement()
        ..classes = ['analysis-select']
        ..value = modeToString(_mode)
        ..children = HeapSnapshotTreeMode.values.map((mode) {
          return new OptionElement(
              value: modeToString(mode), selected: _mode == mode)
            ..text = modeToString(mode);
        }).toList(growable: false)
        ..onChange.listen((_) {
          _mode = HeapSnapshotTreeMode.values[s.selectedIndex];
          _r.dirty();
        })
    ];
  }
}
