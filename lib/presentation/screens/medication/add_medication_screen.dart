/// Medora - Add/Edit Medication Screen
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/platform_capabilities.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/core/theme_extensions.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/medication/aifa_search_sheet.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';
import 'package:medora/presentation/widgets/forms/tag_input_field.dart';
import 'package:medora/presentation/widgets/forms/unit_dropdown.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:uuid/uuid.dart';

class AddMedicationScreen extends ConsumerStatefulWidget {
  const AddMedicationScreen({
    super.key,
    this.medicationId,
    this.initialBarcode,
    this.lookupResult,
  });

  final String? medicationId;
  final String? initialBarcode;
  final Object? lookupResult;

  @override
  ConsumerState<AddMedicationScreen> createState() =>
      _AddMedicationScreenState();
}

class _AddMedicationScreenState extends ConsumerState<AddMedicationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _uuid = const Uuid();

  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _manufacturerController;
  late final TextEditingController _formController;
  late final TextEditingController _atcCodeController;
  late final TextEditingController _quantityController;
  late final TextEditingController _minStockController;
  late final TextEditingController _storageLocationController;
  late final TextEditingController _barcodeController;
  late final TextEditingController _notesController;

  // Force-expand the section containing a failing field or, in edit mode,
  // a section that already has data. See [FormSection.controller].
  // Starts false (Basics is opened by FormSection.initiallyExpanded, not by
  // this controller) so a later `.value = true` from a validator after a
  // manual collapse is a real transition and notifies listeners — a
  // same-value assignment (true -> true) would be a ValueNotifier no-op.
  final _basicsExpanded = ValueNotifier<bool>(false);
  final _stockExpanded = ValueNotifier<bool>(false);
  final _detailsExpanded = ValueNotifier<bool>(false);

  List<String> _activeIngredients = [];
  List<String> _symptoms = [];
  List<String> _patientTags = [];
  String? _selectedCategory;
  String? _quantityUnit;
  DateTime? _purchaseDate;
  DateTime? _expiryDate;
  bool _isLoading = false;
  bool _isEditMode = false;
  Medication? _existingMedication;
  String? _imagePath;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descriptionController = TextEditingController();
    _manufacturerController = TextEditingController();
    _formController = TextEditingController();
    _atcCodeController = TextEditingController();
    _quantityController = TextEditingController(text: '1');
    _minStockController = TextEditingController(
        text: AppConstants.defaultMinimumStock.toString());
    _storageLocationController = TextEditingController();
    _barcodeController = TextEditingController(text: widget.initialBarcode);
    _notesController = TextEditingController();

    _isEditMode = widget.medicationId != null;
    if (!_isEditMode && widget.lookupResult is AifaSearchResult) {
      _applyAifaResult(widget.lookupResult! as AifaSearchResult);
    }
  }

  bool _didLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isEditMode && !_didLoad) {
      _didLoad = true;
      _loadExistingMedication();
    }
  }

  /// Apply AIFA lookup result to form fields.
  void _applyAifaResult(AifaSearchResult result) {
    if (result.name.isNotEmpty) {
      _nameController.text = result.name;
    }
    if (result.description.isNotEmpty) {
      _descriptionController.text = result.description;
    }
    if (result.activeIngredient != null &&
        result.activeIngredient!.isNotEmpty) {
      _activeIngredients = result.activeIngredient!
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (result.manufacturer != null && result.manufacturer!.isNotEmpty) {
      _manufacturerController.text = result.manufacturer!;
    }
    if (result.form != null && result.form!.isNotEmpty) {
      _formController.text = result.form!;
    }
    if (result.atcCode != null && result.atcCode!.isNotEmpty) {
      _atcCodeController.text = result.atcCode!;
    }
    _barcodeController.text = result.code;
  }

  /// Whether [med] has any data belonging to the Stock & storage section.
  bool _hasStockData(Medication med) {
    return med.minimumStockLevel != AppConstants.defaultMinimumStock ||
        (med.storageLocation?.isNotEmpty ?? false) ||
        med.purchaseDate != null ||
        (med.barcode?.isNotEmpty ?? false);
  }

  /// Whether [med] has any data belonging to the Details section.
  bool _hasDetailsData(Medication med) {
    return (med.description?.isNotEmpty ?? false) ||
        med.activeIngredients.isNotEmpty ||
        med.symptoms.isNotEmpty ||
        med.patientTags.isNotEmpty ||
        med.category != null ||
        (med.manufacturer?.isNotEmpty ?? false) ||
        (med.atcCode?.isNotEmpty ?? false) ||
        med.imagePath != null ||
        (med.notes?.isNotEmpty ?? false);
  }

  Future<void> _loadExistingMedication() async {
    final l10n = AppLocalizations.of(context);
    final repo = ref.read(medicationRepositoryProvider);
    final result = await repo.getMedicationById(widget.medicationId!);
    result.when(
      success: (med) {
        setState(() {
          _existingMedication = med;
          _nameController.text = med.name;
          _descriptionController.text = med.description ?? '';
          _activeIngredients = List.of(med.activeIngredients);
          _symptoms = List.of(med.symptoms);
          _patientTags = List.of(med.patientTags);
          _selectedCategory = med.category;
          _quantityUnit = med.quantityUnit;
          _manufacturerController.text = med.manufacturer ?? '';
          _formController.text = med.form ?? '';
          _atcCodeController.text = med.atcCode ?? '';
          _purchaseDate = med.purchaseDate;
          _expiryDate = med.expiryDate;
          _quantityController.text = med.quantity.toString();
          _minStockController.text = med.minimumStockLevel.toString();
          _storageLocationController.text = med.storageLocation ?? '';
          _barcodeController.text = med.barcode ?? '';
          _notesController.text = med.notes ?? '';
          _imagePath = med.imagePath;
        });
        if (_hasStockData(med)) _stockExpanded.value = true;
        if (_hasDetailsData(med)) _detailsExpanded.value = true;
      },
      failure: (msg) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.errorLoadingMedication(msg))),
        );
      },
    );
  }

  /// Push the barcode scanner and fill [_barcodeController] with the result.
  Future<void> _openScanner() async {
    final barcode = await context.push<String>(AppRoutes.scanner);
    if (barcode != null && mounted) {
      setState(() => _barcodeController.text = barcode);
    }
  }

  /// Search AIFA database by code and apply the result.
  Future<void> _searchBarcode(String barcode) async {
    final l10n = AppLocalizations.of(context);

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(l10n.lookingUpBarcode),
          ],
        ),
        duration: const Duration(seconds: 30),
      ),
    );

    try {
      final results = await AifaCacheService.instance.search(barcode);

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.barcodeNotFound)),
        );
        return;
      }

      // Pick from results
      final selected = results.length == 1
          ? results.first
          : await showAifaResultsPicker(context, results,
              title: l10n.selectMedication);

      if (selected == null || !mounted) return;

      _applyAifaResult(selected);
      setState(() {}); // rebuild
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.autoFilledFromBarcode)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.barcodeNotFound)),
        );
      }
    }
  }

  /// Search AIFA database by medication name text.
  Future<void> _showAifaTextSearch(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final selected = await showAifaSearchSheet(context);
    if (selected == null || !mounted) return;
    _applyAifaResult(selected);
    setState(() {});
    if (mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.autoFilledFromBarcode)),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _manufacturerController.dispose();
    _formController.dispose();
    _atcCodeController.dispose();
    _quantityController.dispose();
    _minStockController.dispose();
    _storageLocationController.dispose();
    _barcodeController.dispose();
    _notesController.dispose();
    _basicsExpanded.dispose();
    _stockExpanded.dispose();
    _detailsExpanded.dispose();
    super.dispose();
  }

  /// Collapsed-state summary for the Stock & storage section, e.g. "10
  /// Pills · min 2".
  String _stockSummary(AppLocalizations l10n) {
    final qty = _quantityController.text.trim();
    final unit = (_quantityUnit != null && _quantityUnit!.isNotEmpty)
        ? AppConstants.unitLabel(l10n, _quantityUnit!)
        : '';
    final qtyPart = [qty, unit].where((s) => s.isNotEmpty).join(' ');
    final minStock = int.tryParse(_minStockController.text.trim()) ?? 0;
    final minPart = l10n.minStockShort(minStock);
    return qtyPart.isEmpty ? minPart : '$qtyPart · $minPart';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final caps = ref.watch(platformCapabilitiesProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(
            _isEditMode ? l10n.editMedication : l10n.addMedicationButton),
        actions: [
          if (!_isEditMode) ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: l10n.searchAifaByName,
              onPressed: () => _showAifaTextSearch(context),
            ),
            if (caps.hasCamera)
              IconButton(
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: l10n.scanBarcodeTooltip,
                onPressed: _openScanner,
              ),
          ],
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_isEditMode) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (caps.hasCamera)
                    ActionChip(
                      avatar: const Icon(Icons.qr_code_scanner, size: 18),
                      label: Text(l10n.scanBarcodeTooltip),
                      onPressed: _openScanner,
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.search, size: 18),
                    label: Text(l10n.searchAifaByName),
                    onPressed: () => _showAifaTextSearch(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],

            // ── Basics ──
            FormSection(
              title: l10n.sectionBasics,
              icon: Icons.medication,
              controller: _basicsExpanded,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: l10n.medicationNameLabel,
                    prefixIcon: const Icon(Icons.medication),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      _basicsExpanded.value = true;
                      return l10n.pleaseEnterMedicationName;
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _formController,
                  decoration: InputDecoration(
                    labelText: l10n.formLabel,
                    prefixIcon: const Icon(Icons.medical_information),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _quantityController,
                        decoration: InputDecoration(
                          labelText: l10n.quantityLabel,
                          prefixIcon: const Icon(Icons.inventory_2),
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            _basicsExpanded.value = true;
                            return l10n.required;
                          }
                          if (int.tryParse(value) == null) {
                            _basicsExpanded.value = true;
                            return l10n.invalidNumber;
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: UnitDropdown(
                        value: _quantityUnit,
                        onChanged: (v) => setState(() => _quantityUnit = v),
                        decoration: InputDecoration(
                          labelText: l10n.quantityUnit,
                          prefixIcon: const Icon(Icons.straighten),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DatePickerField(
                  label: l10n.expiryDate,
                  icon: Icons.event,
                  date: _expiryDate,
                  onDateSelected: (date) =>
                      setState(() => _expiryDate = date),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Stock & storage ──
            FormSection(
              title: l10n.sectionStock,
              icon: Icons.inventory_2,
              initiallyExpanded: false,
              controller: _stockExpanded,
              summary: _stockSummary(l10n),
              children: [
                TextFormField(
                  controller: _minStockController,
                  decoration: InputDecoration(
                    labelText: l10n.minStock,
                    prefixIcon: const Icon(Icons.low_priority),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('loc_${_storageLocationController.text}'),
                  initialValue: AppConstants.storageLocationKeys.contains(
                          _storageLocationController.text)
                      ? _storageLocationController.text
                      : null,
                  decoration: InputDecoration(
                    labelText: l10n.storageLocation,
                    prefixIcon: const Icon(Icons.place),
                  ),
                  items: AppConstants.storageLocationKeys.map((key) {
                    return DropdownMenuItem(
                      value: key,
                      child: Text(AppConstants.storageLabel(l10n, key)),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(
                        () => _storageLocationController.text = value ?? '');
                  },
                ),
                const SizedBox(height: 16),
                DatePickerField(
                  label: l10n.purchaseDate,
                  icon: Icons.shopping_cart,
                  date: _purchaseDate,
                  onDateSelected: (date) =>
                      setState(() => _purchaseDate = date),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _barcodeController,
                  decoration: InputDecoration(
                    labelText: l10n.barcode,
                    prefixIcon: const Icon(Icons.qr_code),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Search MyHealthBox by barcode text
                        IconButton(
                          icon: const Icon(Icons.search),
                          tooltip: l10n.searchByBarcode,
                          onPressed: _barcodeController.text.trim().isNotEmpty
                              ? () =>
                                  _searchBarcode(_barcodeController.text.trim())
                              : null,
                        ),
                        // Open camera scanner
                        if (caps.hasCamera)
                          IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            onPressed: () async {
                              final barcode = await context.push<String>(
                                  '${AppRoutes.scanner}?returnOnly=true');
                              if (barcode != null && mounted) {
                                setState(
                                    () => _barcodeController.text = barcode);
                                _searchBarcode(barcode);
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onFieldSubmitted: (value) {
                    if (value.trim().isNotEmpty) {
                      _searchBarcode(value.trim());
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Details ──
            FormSection(
              title: l10n.sectionDetails,
              icon: Icons.notes,
              initiallyExpanded: false,
              controller: _detailsExpanded,
              children: [
                TextFormField(
                  controller: _descriptionController,
                  decoration: InputDecoration(
                    labelText: l10n.medicationDescription,
                    prefixIcon: const Icon(Icons.description),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                TagInputField(
                  label: l10n.activeIngredients,
                  icon: Icons.science,
                  tags: _activeIngredients,
                  onChanged: (tags) =>
                      setState(() => _activeIngredients = tags),
                ),
                const SizedBox(height: 16),
                TagInputField(
                  label: l10n.symptomsField,
                  icon: Icons.local_hospital,
                  tags: _symptoms,
                  onChanged: (tags) => setState(() => _symptoms = tags),
                ),
                const SizedBox(height: 16),
                TagInputField(
                  label: l10n.patientTagsField,
                  icon: Icons.person,
                  tags: _patientTags,
                  onChanged: (tags) => setState(() => _patientTags = tags),
                  isUserTag: true,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('cat_$_selectedCategory'),
                  initialValue: _selectedCategory,
                  decoration: InputDecoration(
                    labelText: l10n.category,
                    prefixIcon: const Icon(Icons.category),
                  ),
                  items: AppConstants.medicationCategoryKeys.map((key) {
                    return DropdownMenuItem(
                      value: key,
                      child: Text(AppConstants.categoryLabel(l10n, key)),
                    );
                  }).toList(),
                  onChanged: (value) =>
                      setState(() => _selectedCategory = value),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _manufacturerController,
                  decoration: InputDecoration(
                    labelText: l10n.manufacturerLabel,
                    prefixIcon: const Icon(Icons.factory),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _atcCodeController,
                  decoration: InputDecoration(
                    labelText: l10n.atcCodeLabel,
                    prefixIcon: const Icon(Icons.code),
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
                if (!kIsWeb) ...[
                  const SizedBox(height: 16),
                  _buildPhotoSection(l10n),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notesController,
                  decoration: InputDecoration(
                    labelText: l10n.notes,
                    prefixIcon: const Icon(Icons.notes),
                  ),
                  maxLines: 3,
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: 50,
            width: double.infinity,
            child: FilledButton(
              onPressed: _isLoading ? null : _saveMedication,
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isEditMode
                      ? l10n.updateMedication
                      : l10n.addMedicationButton),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoSection(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.medicationPhoto,
            style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _pickImage,
          child: Container(
            height: 150,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.colors.outlineVariant),
            ),
            child: _imagePath == null || kIsWeb
                ? _photoPlaceholder(l10n)
                : ref.watch(resolvedPhotoProvider(_imagePath)).maybeWhen(
                    data: (file) {
                      if (file == null) return _photoPlaceholder(l10n);
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(file,
                            fit: BoxFit.cover, width: double.infinity),
                      );
                    },
                    orElse: () => _photoPlaceholder(l10n),
                  ),
          ),
        ),
        if (_imagePath != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                if (!_isEditMode || _imagePath != _existingMedication?.imagePath) {
                  await ref.read(photoStorageProvider).delete(_imagePath);
                }
                if (!mounted) return;
                setState(() => _imagePath = null);
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(l10n.delete),
            ),
          ),
        ],
      ],
    );
  }

  Widget _photoPlaceholder(AppLocalizations l10n) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_a_photo, size: 40, color: context.colors.outline),
        const SizedBox(height: 8),
        Text(l10n.addPhoto, style: TextStyle(color: context.colors.outline)),
      ],
    );
  }

  Future<void> _pickImage() async {
    if (kIsWeb) {
      // Photo picking is limited on web in this implementation
      return;
    }
    final l10n = AppLocalizations.of(context);
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(l10n.camera),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l10n.gallery),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, maxWidth: 1024);
    if (picked == null || !mounted) return;

    final name = await ref.read(photoStorageProvider).saveFromPath(picked.path);
    if (!mounted) return;
    setState(() => _imagePath = name);
  }

  /// Pop the screen if it was pushed onto a router (a no-op, e.g. in widget
  /// tests that host the screen directly without a GoRouter ancestor).
  void _popIfPossible() {
    final router = GoRouter.maybeOf(context);
    if (router != null && router.canPop()) {
      router.pop();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _saveMedication() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    final l10n = AppLocalizations.of(context);

    final medication = Medication(
      id: _existingMedication?.id ?? _uuid.v4(),
      userId: SupabaseConfig.currentUserId,
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
      activeIngredients: _activeIngredients,
      category: _selectedCategory,
      manufacturer: _manufacturerController.text.trim().isEmpty
          ? null
          : _manufacturerController.text.trim(),
      form: _formController.text.trim().isEmpty
          ? null
          : _formController.text.trim(),
      atcCode: _atcCodeController.text.trim().isEmpty
          ? null
          : _atcCodeController.text.trim(),
      symptoms: _symptoms,
      patientTags: _patientTags,
      purchaseDate: _purchaseDate,
      expiryDate: _expiryDate,
      quantity: int.tryParse(_quantityController.text) ?? 0,
      quantityUnit: _quantityUnit,
      minimumStockLevel: int.tryParse(_minStockController.text) ?? 0,
      storageLocation: _storageLocationController.text.trim().isEmpty
          ? null
          : _storageLocationController.text.trim(),
      barcode: _barcodeController.text.trim().isEmpty
          ? null
          : _barcodeController.text.trim(),
      imagePath: _imagePath,
      notes: _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
    );

    try {
      if (_isEditMode) {
        await ref
            .read(medicationListProvider.notifier)
            .updateMedication(medication);
      } else {
        await ref
            .read(medicationListProvider.notifier)
            .addMedication(medication);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEditMode
                  ? l10n.medicationUpdatedSuccessfully
                  : l10n.medicationAddedSuccessfully,
            ),
          ),
        );
        _popIfPossible();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.errorWithDetails(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
