import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../shared/widgets/jibi_design.dart';

class JibiShellTab {
  const JibiShellTab({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.child,
    this.lazy = false,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget child;

  /// A lazy tab builds its navigator the first time it is selected instead of
  /// with the shell.
  final bool lazy;
}

/// One slot of the bottom bar: either a tab of the shell or a plain action.
class JibiBarItem {
  /// A destination backed by `tabs[tabIndex]`.
  const JibiBarItem.tab(int this.tabIndex)
    : label = null,
      icon = null,
      selectedIcon = null,
      onPressed = null;

  /// A slot that runs [onPressed] instead of switching tab and is never shown
  /// as selected.
  const JibiBarItem.action({
    required String this.label,
    required IconData this.icon,
    required VoidCallback this.onPressed,
    IconData? selectedIcon,
  }) : tabIndex = null,
       selectedIcon = selectedIcon ?? icon;

  final int? tabIndex;
  final String? label;
  final IconData? icon;
  final IconData? selectedIcon;
  final VoidCallback? onPressed;
}

/// A second bottom-bar layout the shell switches to while one of
/// [activeWhen] is the selected tab (for example the accounts section).
///
/// Its bar has its own items and quick-add actions. Leaving it (through an
/// item that selects a tab outside [activeWhen]) restores the shell's normal
/// bar.
class JibiShellLayout {
  const JibiShellLayout({
    required this.items,
    required this.activeWhen,
    required this.primaryIndex,
    this.quickActions = const [],
    this.quickAddTitle = 'إضافة سريعة',
    this.quickAddOnPushedPages = true,
  });

  final List<JibiBarItem> items;

  /// Selected tab indexes for which this layout replaces the normal bar.
  final Set<int> activeWhen;

  /// The layout's home tab: Back from another tab of the layout goes here
  /// before leaving the layout.
  final int primaryIndex;
  final List<JibiQuickAction> quickActions;
  final String quickAddTitle;

  /// Whether the "+" stays on detail pages pushed inside the tab (the normal
  /// bar shows it on tab roots only).
  final bool quickAddOnPushedPages;
}

/// One entry of the quick-add sheet opened by the bar's centre "+" button.
class JibiQuickAction {
  const JibiQuickAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.description,
  });

  final String label;
  final String? description;
  final IconData icon;
  final VoidCallback onPressed;
}

/// Presentation shell with no dependency on data, routing, or repositories.
///
/// The bottom bar is a notched [BottomAppBar] with a docked centre "+" button
/// that opens a quick-add sheet ([quickActions]). The button and the notch
/// only exist while the active tab shows its root page and the keyboard is
/// closed, so detail pages and forms never carry a second "+".
///
/// Every tab owns a nested [Navigator] so pushed detail pages keep the bottom
/// bar pinned on screen. Switching tabs preserves each tab's route stack; the
/// Android back button first pops the active tab's stack, then returns to the
/// first tab, then leaves the app.
class JibiAppShell extends StatefulWidget {
  const JibiAppShell({
    required this.tabs,
    super.key,
    this.appBar,
    this.quickActions = const [],
    this.quickAddTitle = 'إضافة سريعة',
    this.initialIndex = 0,
    this.onDestinationSelected,
    this.barTabIndices,
    this.alternateLayout,
  }) : assert(tabs.length >= 2),
       assert(initialIndex >= 0 && initialIndex < tabs.length);

  final List<JibiShellTab> tabs;
  final PreferredSizeWidget? appBar;
  final List<JibiQuickAction> quickActions;
  final String quickAddTitle;
  final int initialIndex;
  final ValueChanged<int>? onDestinationSelected;

  /// The tabs shown in the normal bar, in order. Defaults to every tab; set it
  /// when extra tabs exist only for [alternateLayout].
  final List<int>? barTabIndices;

  /// A second bar shown while one of its tabs is selected.
  final JibiShellLayout? alternateLayout;

  @override
  JibiAppShellState createState() => JibiAppShellState();
}

class JibiAppShellState extends State<JibiAppShell> {
  late int _selectedIndex = widget.initialIndex;

  /// Lazy tabs are built the first time they are selected.
  late final Set<int> _visited = <int>{
    for (var index = 0; index < widget.tabs.length; index++)
      if (!widget.tabs[index].lazy || index == widget.initialIndex) index,
  };

  JibiShellLayout? get _activeLayout {
    final layout = widget.alternateLayout;
    return layout != null && layout.activeWhen.contains(_selectedIndex)
        ? layout
        : null;
  }

  /// The tab that is showing.
  int get selectedIndex => _selectedIndex;

  /// Key of the docked "+" button, for the hint tours.
  final GlobalKey fabKey = GlobalKey(debugLabel: 'jibi-quick-add-fab');

  final Map<int, GlobalKey> _tabBarKeys = <int, GlobalKey>{};

  /// Key of the bottom-bar destination that selects tab [tabIndex], for the
  /// hint tours. Only the destinations of the bar being shown are mounted.
  GlobalKey tabBarKey(int tabIndex) => _tabBarKeys.putIfAbsent(
    tabIndex,
    () => GlobalKey(debugLabel: 'jibi-bar-tab-$tabIndex'),
  );

  late final List<GlobalKey<NavigatorState>> _navigatorKeys = List.generate(
    widget.tabs.length,
    (index) => GlobalKey<NavigatorState>(debugLabel: 'jibi-tab-$index'),
  );
  late final List<bool> _atRoot = List<bool>.filled(widget.tabs.length, true);
  late final List<_RootObserver> _observers = List.generate(
    widget.tabs.length,
    (index) => _RootObserver((atRoot) => _setAtRoot(index, atRoot)),
  );

  /// Programmatically selects a tab (used by the top-bar wallet shortcut).
  void selectTab(int index) {
    if (index < 0 || index >= widget.tabs.length) {
      return;
    }
    _select(index);
  }

  /// Pushes [page] inside the currently selected tab, keeping the bottom bar
  /// pinned at the bottom of the screen. Detail pages should use this instead
  /// of the root navigator.
  Future<T?> pushPage<T>(Widget page) {
    return _navigatorKeys[_selectedIndex].currentState!.push<T>(
      MaterialPageRoute<T>(builder: (_) => page),
    );
  }

  void _setAtRoot(int index, bool value) {
    if (_atRoot[index] == value || !mounted) {
      return;
    }
    _atRoot[index] = value;
    void rebuild() {
      if (mounted) setState(() {});
    }

    // Navigator observers can fire while the tree is building.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => rebuild());
    } else {
      rebuild();
    }
  }

  void _select(int index) {
    if (index == _selectedIndex) {
      // Re-tapping the active destination pops its stack back to the root,
      // matching the standard bottom-navigation behaviour.
      _navigatorKeys[index].currentState?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() {
      _selectedIndex = index;
      _visited.add(index);
    });
    widget.onDestinationSelected?.call(index);
  }

  void _onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      return;
    }
    final navigator = _navigatorKeys[_selectedIndex].currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return;
    }
    // Inside an alternate layout, Back first returns to that layout's home tab.
    final primary = _activeLayout?.primaryIndex;
    if (primary != null && _selectedIndex != primary) {
      _select(primary);
    } else if (_selectedIndex != 0) {
      _select(0);
    } else {
      SystemNavigator.pop();
    }
  }

  Future<void> _openQuickAdd() async {
    final layout = _activeLayout;
    final action = await showModalBottomSheet<JibiQuickAction>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // The sheet must cover the bottom bar, not sit under a tappable copy.
      useRootNavigator: true,
      builder: (sheetContext) => _QuickAddSheet(
        title: layout?.quickAddTitle ?? widget.quickAddTitle,
        actions: layout?.quickActions ?? widget.quickActions,
      ),
    );
    if (action != null && mounted) {
      action.onPressed();
    }
  }

  List<_BarEntry> _barEntries(JibiShellLayout? layout) {
    final items =
        layout?.items ??
        <JibiBarItem>[
          for (final index
              in widget.barTabIndices ??
                  List<int>.generate(widget.tabs.length, (index) => index))
            JibiBarItem.tab(index),
        ];
    return [
      for (final item in items)
        if (item.tabIndex != null)
          _BarEntry(
            label: widget.tabs[item.tabIndex!].label,
            icon: widget.tabs[item.tabIndex!].icon,
            selectedIcon: widget.tabs[item.tabIndex!].selectedIcon,
            selected: item.tabIndex == _selectedIndex,
            onPressed: () => _select(item.tabIndex!),
            key: tabBarKey(item.tabIndex!),
          )
        else
          _BarEntry(
            label: item.label!,
            icon: item.icon!,
            selectedIcon: item.selectedIcon!,
            selected: false,
            onPressed: item.onPressed!,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final atRoot = _atRoot[_selectedIndex];
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final layout = _activeLayout;
    final quickActions = layout?.quickActions ?? widget.quickActions;
    final showQuickAdd =
        quickActions.isNotEmpty &&
        !keyboardOpen &&
        (atRoot || (layout?.quickAddOnPushedPages ?? false));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onPopInvokedWithResult,
      child: Scaffold(
        appBar: atRoot ? widget.appBar : null,
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            for (var index = 0; index < widget.tabs.length; index++)
              if (_visited.contains(index))
                TickerMode(
                  enabled: index == _selectedIndex,
                  child: Navigator(
                    key: _navigatorKeys[index],
                    observers: [_observers[index]],
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => widget.tabs[index].child,
                    ),
                  ),
                )
              else
                const SizedBox.shrink(),
          ],
        ),
        floatingActionButton: showQuickAdd
            ? FloatingActionButton(
                key: fabKey,
                heroTag: 'jibi-quick-add',
                tooltip: layout?.quickAddTitle ?? widget.quickAddTitle,
                onPressed: _openQuickAdd,
                child: const Icon(Icons.add, size: 30),
              )
            : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
        bottomNavigationBar: keyboardOpen
            ? null
            : _JibiBottomBar(
                entries: _barEntries(layout),
                hasCenterAction: showQuickAdd,
              ),
      ),
    );
  }
}

/// Tells the shell whether a tab is showing its first (root) route.
class _RootObserver extends NavigatorObserver {
  _RootObserver(this._onChanged);

  final ValueChanged<bool> _onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _onChanged(previousRoute == null);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _onChanged(previousRoute == null || previousRoute.isFirst);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _onChanged(previousRoute == null || previousRoute.isFirst);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _onChanged(newRoute == null || newRoute.isFirst);
}

/// Pushes [page] inside the nearest [JibiAppShell] tab so the bottom bar
/// stays pinned. Falls back to the root navigator when no shell is found
/// (for example standalone pages in widget tests). Use for detail pages.
Future<T?> pushShellPage<T>(BuildContext context, Widget page) {
  final shell = context.findAncestorStateOfType<JibiAppShellState>();
  if (shell != null) {
    return shell.pushPage<T>(page);
  }
  return Navigator.of(context)
      .push<T>(MaterialPageRoute<T>(builder: (_) => page));
}

/// Pushes a create/edit form on the root navigator so it fills the screen
/// without the bottom bar or the quick-add button.
Future<T?> pushFormPage<T>(BuildContext context, Widget page) {
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push<T>(MaterialPageRoute<T>(builder: (_) => page));
}

class _QuickAddSheet extends StatelessWidget {
  const _QuickAddSheet({required this.title, required this.actions});

  final String title;
  final List<JibiQuickAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 8),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            for (final action in actions)
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                leading: CircleAvatar(
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: Icon(action.icon),
                ),
                title: Text(
                  action.label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: action.description == null
                    ? null
                    : Text(action.description!),
                onTap: () => Navigator.of(context).pop(action),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the bottom bar draws for one slot (a tab or an action).
class _BarEntry {
  const _BarEntry({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onPressed,
    this.key,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onPressed;

  /// Set on tab destinations so a hint tour can point at them.
  final GlobalKey? key;
}

class _JibiBottomBar extends StatelessWidget {
  const _JibiBottomBar({required this.entries, required this.hasCenterAction});

  final List<_BarEntry> entries;

  /// Whether the docked "+" is shown, which leaves a gap in the middle.
  final bool hasCenterAction;

  @override
  Widget build(BuildContext context) {
    final centerIndex = (entries.length / 2).floor() - 1;
    return BottomAppBar(
      shape: hasCenterAction ? const CircularNotchedRectangle() : null,
      notchMargin: 8,
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          for (var index = 0; index < entries.length; index++) ...[
            Expanded(
              child: KeyedSubtree(
                key: entries[index].key,
                child: _Destination(entry: entries[index]),
              ),
            ),
            if (entries.length >= 3 && index == centerIndex)
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: hasCenterAction ? 72 : 0,
              ),
          ],
        ],
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  const _Destination({required this.entry});

  final _BarEntry entry;

  bool get selected => entry.selected;
  VoidCallback get onSelect => entry.onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final inactive = context.jibiMuted;
    final tint = selected ? colors.primary : inactive;
    return Semantics(
      button: true,
      selected: selected,
      label: entry.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onSelect,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 52,
              height: 30,
              decoration: BoxDecoration(
                color: selected
                    ? colors.primary.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(
                selected ? entry.selectedIcon : entry.icon,
                size: 24,
                color: tint,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: tint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
