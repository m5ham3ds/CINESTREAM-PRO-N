import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/app_palette.dart';
import '../../design/app_tokens.dart';
import '../../mobile/widgets/page_kit.dart';
import '../../ui_components/app_ui_components.dart';
import '../../video_providers/unified/source_manifest.dart';
import '../../video_providers/unified/source_repository_manager.dart';
import '../../video_providers/unified/unified_source_service.dart';

/// User-facing management for source repositories and their installed engines.
/// Unsupported engines remain visible, but are never executed by the runtime.
class SourceRepositoriesScreen extends StatefulWidget {
  const SourceRepositoriesScreen({super.key});

  @override
  State<SourceRepositoriesScreen> createState() =>
      _SourceRepositoriesScreenState();
}

class _SourceRepositoriesScreenState extends State<SourceRepositoriesScreen> {
  final UnifiedSourceService _service = UnifiedSourceService();
  final TextEditingController _repositoryController = TextEditingController();

  bool _loading = true;
  bool _working = false;
  SourceRepositorySyncResult? _snapshot;
  List<String> _repositories = const <String>[];
  Set<String> _installed = <String>{};
  Set<String> _disabledDefaults = <String>{};
  String? _pageError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _repositoryController.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool showBusy = true}) async {
    if (showBusy && mounted) setState(() => _loading = true);
    try {
      final snapshot = await _service.refreshRepositories(forceRefresh: true);
      final repositories = await _service.repositoryUrls();
      final installed = await _service.installedSourceKeys();
      final disabledDefaults = await _service.disabledDefaultSourceKeys();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _repositories = repositories;
        _installed = installed;
        _disabledDefaults = disabledDefaults;
        _pageError = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _pageError = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addRepository([String? suppliedUrl]) async {
    final url = (suppliedUrl ?? _repositoryController.text).trim();
    if (url.isEmpty || _working) return;
    setState(() => _working = true);
    try {
      await _service.addRepository(url);
      _repositoryController.clear();
      await _refresh(showBusy: false);
      if (mounted) _message(tr('source_repository_added'));
    } catch (error) {
      if (mounted) _message('${tr('repository_error')}: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _removeRepository(String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('remove_repository')),
        content: Text(url),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('cancel')),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('remove')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.removeRepository(url);
      await _refresh(showBusy: false);
      if (mounted) _message(tr('source_repository_removed'));
    } catch (error) {
      if (mounted) _message('${tr('repository_error')}: $error');
    }
  }

  Future<void> _setInstalled(SourceManifest source, bool install) async {
    try {
      if (install) {
        await _service.installSource(source);
      } else {
        await _service.uninstallSource(source);
      }
      await _refresh(showBusy: false);
    } catch (error) {
      if (mounted) _message('${tr('repository_error')}: $error');
    }
  }

  bool _isInstalled(SourceManifest source) =>
      _installed.contains(source.stableKey) ||
      (source.installedByDefault &&
          !_disabledDefaults.contains(source.stableKey));

  Future<void> _copyConfiguration() async {
    try {
      final raw = await _service.exportConfiguration();
      await Clipboard.setData(ClipboardData(text: raw));
      if (mounted) _message(tr('configuration_copied'));
    } catch (error) {
      if (mounted) _message('${tr('repository_error')}: $error');
    }
  }

  Future<void> _importConfiguration() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('import_source_configuration')),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            minLines: 5,
            maxLines: 10,
            decoration: InputDecoration(
              hintText: tr('paste_source_configuration'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(tr('import')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    try {
      await _service.importConfiguration(raw);
      await _refresh();
      if (mounted) _message(tr('configuration_imported'));
    } catch (error) {
      if (mounted) _message('${tr('repository_error')}: $error');
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final catalog = _snapshot?.catalog ?? const <SourceManifest>[];
    final installedSources = catalog.where(_isInstalled).toList(growable: false);
    final unsupportedCount = installedSources
        .where((source) => !_supportsRuntime(source))
        .length;

    return Scaffold(
      backgroundColor: palette.page,
      appBar: PageAppBar(
        title: tr('source_manager'),
        contentWidth: 900,
        actions: <Widget>[
          IconButton(
            tooltip: tr('refresh_sources'),
            onPressed: _loading ? null : () => _refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          PopupMenuButton<String>(
            tooltip: tr('source_configuration'),
            onSelected: (value) => value == 'export'
                ? _copyConfiguration()
                : _importConfiguration(),
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem(value: 'export', child: Text(tr('export_configuration'))),
              PopupMenuItem(value: 'import', child: Text(tr('import_configuration'))),
            ],
          ),
        ],
      ),
      body: AppResponsiveContent(
        maxWidth: 900,
        child: _loading && _snapshot == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  AppSpace.gutter(context),
                  AppSpace.md,
                  AppSpace.gutter(context),
                  AppSpace.xxxl + MediaQuery.paddingOf(context).bottom,
                ),
                children: <Widget>[
                  _IntroCard(
                    description: tr('source_manager_description'),
                    installedCount: installedSources.length,
                    catalogCount: catalog.length,
                    unsupportedCount: unsupportedCount,
                  ),
                  const SizedBox(height: AppSpace.lg),
                  _SectionHeading(title: tr('add_source_repository')),
                  Material(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(AppRadii.card),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.md),
                      child: Column(
                        children: <Widget>[
                          TextField(
                            controller: _repositoryController,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _addRepository(),
                            decoration: InputDecoration(
                              labelText: tr('source_repository_url'),
                              hintText: 'https://example.com/index.json',
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                tooltip: tr('add_repository'),
                                onPressed: _working ? null : _addRepository,
                                icon: const Icon(Icons.add_rounded),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpace.sm),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: OutlinedButton.icon(
                              onPressed: _working
                                  ? null
                                  : () => _addRepository(
                                        SourceRepositoryManager
                                            .defaultOpenStreamRepository,
                                      ),
                              icon: const Icon(Icons.add_link_rounded),
                              label: Text(tr('add_openstream_repository')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  _SectionHeading(
                    title: tr('repositories'),
                    trailing: Text('${_repositories.length}'),
                  ),
                  if (_repositories.isEmpty)
                    _EmptyPanel(label: tr('no_repositories'))
                  else
                    _SurfacePanel(
                      children: <Widget>[
                        for (var index = 0; index < _repositories.length; index++)
                          _RepositoryTile(
                            url: _repositories[index],
                            error: _snapshot?.errors[_repositories[index]],
                            onRemove: () => _removeRepository(_repositories[index]),
                            showDivider: index != _repositories.length - 1,
                          ),
                      ],
                    ),
                  const SizedBox(height: AppSpace.lg),
                  _SectionHeading(
                    title: tr('source_catalog'),
                    trailing: Text('${catalog.length}'),
                  ),
                  if (_pageError != null)
                    _EmptyPanel(label: _pageError!, isError: true)
                  else if (catalog.isEmpty)
                    _EmptyPanel(label: tr('no_sources_found'))
                  else
                    _SurfacePanel(
                      children: <Widget>[
                        for (var index = 0; index < catalog.length; index++)
                          _SourceTile(
                            source: catalog[index],
                            installed: _isInstalled(catalog[index]),
                            supported: _supportsRuntime(catalog[index]),
                            onChanged: (value) =>
                                _setInstalled(catalog[index], value),
                            showDivider: index != catalog.length - 1,
                          ),
                      ],
                    ),
                  if (_snapshot?.errors.isNotEmpty == true) ...<Widget>[
                    const SizedBox(height: AppSpace.md),
                    Text(
                      tr('some_repositories_failed'),
                      style: AppType.metadata.copyWith(color: palette.mutedText),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  bool _supportsRuntime(SourceManifest source) => _service.supportsSource(source);
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({
    required this.description,
    required this.installedCount,
    required this.catalogCount,
    required this.unsupportedCount,
  });

  final String description;
  final int installedCount;
  final int catalogCount;
  final int unsupportedCount;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppRadii.card),
        border: Border.all(color: palette.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(description, style: AppType.body.copyWith(color: palette.mutedText)),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: <Widget>[
              _CountChip(label: tr('installed_sources'), count: installedCount),
              _CountChip(label: tr('source_catalog'), count: catalogCount),
              if (unsupportedCount > 0)
                _CountChip(
                  label: tr('unsupported_installed'),
                  count: unsupportedCount,
                  warning: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({required this.label, required this.count, this.warning = false});
  final String label;
  final int count;
  final bool warning;

  @override
  Widget build(BuildContext context) => Chip(
        visualDensity: VisualDensity.compact,
        avatar: warning
            ? const Icon(Icons.warning_amber_rounded, size: 16)
            : const Icon(Icons.check_circle_outline_rounded, size: 16),
        label: Text('$label: $count'),
      );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, AppSpace.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: AppType.kicker.copyWith(color: palette.mutedText),
            ),
          ),
          if (trailing != null)
            DefaultTextStyle(
              style: AppType.metadata.copyWith(color: palette.mutedText),
              child: trailing!,
            ),
        ],
      ),
    );
  }
}

class _SurfacePanel extends StatelessWidget {
  const _SurfacePanel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(AppRadii.card),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _RepositoryTile extends StatelessWidget {
  const _RepositoryTile({
    required this.url,
    required this.onRemove,
    required this.showDivider,
    this.error,
  });

  final String url;
  final String? error;
  final VoidCallback onRemove;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Column(
      children: <Widget>[
        ListTile(
          dense: true,
          leading: Icon(
            error == null ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: error == null ? palette.mutedText : Theme.of(context).colorScheme.error,
          ),
          title: Text(url, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: error == null ? null : Text(error!, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            tooltip: tr('remove_repository'),
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ),
        if (showDivider) const Divider(height: 1),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.installed,
    required this.supported,
    required this.onChanged,
    required this.showDivider,
  });

  final SourceManifest source;
  final bool installed;
  final bool supported;
  final ValueChanged<bool> onChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final engineLabel = source.engine.rawType.isEmpty
        ? source.engine.kind.name
        : source.engine.rawType;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 8, 10),
          child: Row(
            children: <Widget>[
              if (source.iconUrl != null && source.iconUrl!.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Image.network(
                    source.iconUrl!,
                    width: 38,
                    height: 38,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _sourceIcon(context),
                  ),
                )
              else
                _sourceIcon(context),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(source.name, style: AppType.cardTitle),
                    const SizedBox(height: 2),
                    Text(
                      '$engineLabel • ${source.language}',
                      style: AppType.metadata.copyWith(color: palette.mutedText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (source.description.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        source.description,
                        style: AppType.metadata.copyWith(color: palette.mutedText),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: AppSpace.xs),
                    Wrap(
                      spacing: AppSpace.xs,
                      runSpacing: AppSpace.xs,
                      children: <Widget>[
                        _SourceStatusChip(
                          label: supported
                              ? tr('supported_engine')
                              : tr('unsupported_engine'),
                          warning: !supported,
                        ),
                        if (source.status == 2)
                          _SourceStatusChip(label: tr('source_slow')),
                        if (source.status == 3)
                          _SourceStatusChip(label: tr('source_beta')),
                        if (source.isNsfw)
                          _SourceStatusChip(label: tr('source_adult'), warning: true),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              if (installed)
                IconButton(
                  tooltip: tr('uninstall'),
                  onPressed: () => onChanged(false),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                )
              else
                IconButton(
                  tooltip: supported ? tr('install') : tr('unsupported_engine'),
                  onPressed: supported ? () => onChanged(true) : null,
                  icon: const Icon(Icons.add_circle_outline_rounded),
                ),
            ],
          ),
        ),
        if (showDivider) const Divider(height: 1),
      ],
    );
  }

  Widget _sourceIcon(BuildContext context) => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: AppPalette.of(context).idleFill,
          borderRadius: BorderRadius.circular(9),
        ),
        child: const Icon(Icons.extension_outlined),
      );
}

class _SourceStatusChip extends StatelessWidget {
  const _SourceStatusChip({required this.label, this.warning = false});
  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: warning
              ? Theme.of(context).colorScheme.errorContainer.withOpacity(.55)
              : AppPalette.of(context).idleFill,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: AppType.metadata),
      );
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.label, this.isError = false});
  final String label;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: AppPalette.of(context).surface,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Text(
          label,
          style: AppType.body.copyWith(
            color: isError ? Theme.of(context).colorScheme.error : AppPalette.of(context).mutedText,
          ),
        ),
      );
}
