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
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/now_provider.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/presentation/screens/medication/aifa_search_sheet.dart';
import 'package:medora/presentation/screens/medication/supplement_search_sheet.dart';
import 'package:medora/presentation/screens/medication/widgets/medication_details_section.dart';
import 'package:medora/presentation/screens/medication/widgets/medication_photo_section.dart';
import 'package:medora/presentation/screens/medication/widgets/medication_stock_section.dart';
import 'package:medora/presentation/screens/scanner/scan_result.dart';
import 'package:medora/presentation/screens/scanner/supplement_register_dialogs.dart';
import 'package:medora/presentation/screens/scanner/supplement_routing.dart';
import 'package:medora/presentation/widgets/forms/date_picker_field.dart';
import 'package:medora/presentation/widgets/forms/form_section.dart';
import 'package:medora/presentation/widgets/forms/unit_dropdown.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:medora/services/code_candidates.dart';
import 'package:medora/services/supplement_registry_service.dart';
import 'package:uuid/uuid.dart';

class AddMedicationScreen extends ConsumerStatefulWidget {
  const AddMedicationScreen({
    super.key,
    this.medicationId,
    this.initialBarcode,
    this.initialEan,
    this.lookupResult,
  });

  final String? medicationId;
  final String? initialBarcode;

  /// The pack's EAN, when the scan that opened this screen read one next
  /// to the label code in [initialBarcode].
  final String? initialEan;

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

  // Two-way synced with FormSection: force-expand the section containing a
  // failing field, or, in edit mode, a section that already has data; a
  // manual header collapse writes back into these too. See
  // [FormSection.controller]. Basics starts expanded; Stock & storage and
  // Details start collapsed and are opened once loaded edit-mode data shows
  // they have content (see [_loadExistingMedication]).
  final _basicsExpanded = ValueNotifier<bool>(true);
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

  /// The pack's EAN, remembered next to the barcode field's label code.
  String? _ean;

  /// The label code [_ean] was read with. A scan or a hand edit that moves
  /// the barcode field to another code drops the remembered EAN with it,
  /// because that EAN belongs to the pack the old code came from.
  String? _eanCode;
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
      text: AppConstants.defaultMinimumStock.toString(),
    );
    _storageLocationController = TextEditingController();
    _barcodeController = TextEditingController(text: widget.initialBarcode);
    _ean = widget.initialEan;
    _eanCode = widget.initialBarcode;
    _notesController = TextEditingController();

    _isEditMode = widget.medicationId != null;
    if (!_isEditMode) {
      switch (widget.lookupResult) {
        case final AifaSearchResult result:
          _applyAifaResult(result);
        case final SupplementEntry entry:
          _applySupplementEntry(entry);
      }
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

  /// Apply a food-supplement register entry: name, manufacturer, the
  /// supplement category and the scanned code (the route's `?barcode=`,
  /// else the register code). Opens the sections that were filled.
  void _applySupplementEntry(SupplementEntry entry) {
    if (entry.product.isNotEmpty) _nameController.text = entry.product;
    if (entry.company.isNotEmpty) {
      _manufacturerController.text = entry.company;
    }
    _selectedCategory = _supplementCategory;
    if (_barcodeController.text.trim().isEmpty) {
      _barcodeController.text = entry.code;
    }
    _stockExpanded.value = true;
    _detailsExpanded.value = true;
  }

  static const _supplementCategory = 'supplement';

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
          _ean = med.ean;
          _eanCode = med.barcode;
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

  /// Push the barcode scanner, fill [_barcodeController] with the chosen
  /// code and look it up where its kind belongs: AIC codes in AIFA,
  /// supplement codes in the food-supplement register; EAN and other numbers
  /// are only filled in.
  Future<void> _openScanner() async {
    final result = await context.push<ScanResult>(AppRoutes.scannerReturnOnly);
    if (result == null || !mounted) return;
    setState(() {
      _barcodeController.text = result.code;
      // A rescan of the same pack whose photo showed no barcode stripe
      // carries no EAN: keep the one already remembered. A scan that read
      // a different code is a different pack, so the old EAN goes.
      if (result.ean != null) {
        _ean = result.ean;
        _eanCode = result.code;
      } else if (result.code != _eanCode) {
        _ean = null;
        _eanCode = null;
      }
    });
    // The barcode field lives in Stock & storage: show what was filled.
    _stockExpanded.value = true;
    switch (result.kind) {
      case CodeKind.aic:
        await _searchBarcode(result.code, result.alternatives);
      case CodeKind.supplement:
        await _searchSupplement(result.code, result.alternatives);
      case CodeKind.ean || CodeKind.other:
        break;
    }
  }

  /// Look a supplement [code] up in the register (offering the first
  /// download), then its [alternatives] (other OCR readings) in order, and
  /// apply the chosen entry with the code that matched. A match found only
  /// through an alternative is confirmed first; the scanned code stays in
  /// the field when nothing matches, the picker is dismissed or the
  /// alternative is declined.
  Future<void> _searchSupplement(
    String code, [
    List<String> alternatives = const [],
  ]) async {
    if (!ref.read(platformCapabilitiesProvider).hasSupplementRegister) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final service = ref.read(supplementRegistryServiceProvider);
    try {
      if (!await service.hasData()) {
        if (!mounted) return;
        final downloaded = await confirmAndDownloadSupplementRegister(
          context,
          service,
        );
        if (!mounted || downloaded == null) return; // cancelled
        if (!downloaded) {
          messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
          return;
        }
      }
      final found = await findSupplementByCodes(service, code, alternatives);
      if (!mounted) return;
      final SupplementEntry? entry;
      switch (supplementRouteFor(found.matches)) {
        case SupplementPrefill(entry: final only):
          entry = only;
        case SupplementPick(:final entries):
          entry = await showSupplementPicker(context, entries);
        case SupplementNotFound():
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.supplementNotFound)),
          );
          return;
      }
      if (entry == null || !mounted) return;
      if (found.code != code) {
        final use = await confirmAlternativeCode(
          context,
          read: code,
          code: found.code,
          product: entry.product,
          company: entry.company,
        );
        if (!mounted) return;
        if (!use) {
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.supplementNotFound)),
          );
          return;
        }
      }
      setState(() {
        _barcodeController.text = found.code;
        _applySupplementEntry(entry!);
      });
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.autoFilledFromBarcode)),
      );
    } catch (e) {
      debugPrint('Supplement register lookup error: $e');
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
      }
    }
  }

  /// Search AIFA database by code, then by its [alternatives] (other OCR
  /// readings) in order, and apply the result; a result found only through
  /// an alternative is confirmed first.
  Future<void> _searchBarcode(
    String barcode, [
    List<String> alternatives = const [],
  ]) async {
    final l10n = AppLocalizations.of(context);

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
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
      final found = await findByCodes(
        AifaCacheService.instance.search,
        barcode,
        alternatives,
      );
      final results = found.matches;

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (results.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.barcodeNotFound)));
        return;
      }

      // Pick from results
      final selected = results.length == 1
          ? results.first
          : await showAifaResultsPicker(
              context,
              results,
              title: l10n.selectMedication,
            );

      if (selected == null || !mounted) return;
      if (found.code != barcode) {
        final use = await confirmAlternativeCode(
          context,
          read: barcode,
          code: found.code,
          product: selected.name,
          company: selected.manufacturer,
        );
        if (!mounted) return;
        if (!use) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l10n.barcodeNotFound)));
          return;
        }
        _barcodeController.text = found.code;
      }

      _applyAifaResult(selected);
      setState(() {}); // rebuild
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.autoFilledFromBarcode)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.barcodeNotFound)));
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

  /// Search the food-supplement register by product name (offering the
  /// first download) and prefill from the chosen product, exactly like a
  /// scanned supplement code does.
  Future<void> _showSupplementSearch() async {
    if (!ref.read(platformCapabilitiesProvider).hasSupplementRegister) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final service = ref.read(supplementRegistryServiceProvider);
    try {
      if (!await service.hasData()) {
        if (!mounted) return;
        final downloaded = await confirmAndDownloadSupplementRegister(
          context,
          service,
        );
        if (!mounted || downloaded == null) return; // cancelled
        if (!downloaded) {
          messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
          return;
        }
      }
      if (!mounted) return;
      final entry = await showSupplementSearchSheet(context, service);
      if (entry == null || !mounted) return;
      setState(() => _applySupplementEntry(entry));
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.autoFilledFromBarcode)),
      );
    } catch (e) {
      debugPrint('Supplement register search error: $e');
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.genericError)));
      }
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
    final now = ref.watch(nowProvider)();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditMode ? l10n.editMedication : l10n.addMedicationButton,
        ),
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
        // A SingleChildScrollView + Column keeps every field mounted at all
        // times (unlike a ListView, which lazily unmounts off-screen
        // children — deactivating their FormFieldState and making
        // Form.validate() silently skip them on a small viewport / large
        // text scale).
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    if (caps.hasSupplementRegister)
                      ActionChip(
                        avatar: const Icon(Icons.eco_outlined, size: 18),
                        label: Text(l10n.searchSupplementByName),
                        onPressed: _showSupplementSearch,
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
                    now: now,
                    onDateSelected: (date) =>
                        setState(() => _expiryDate = date),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ── Stock & storage ──
              MedicationStockSection(
                minStockController: _minStockController,
                storageLocationController: _storageLocationController,
                barcodeController: _barcodeController,
                expanded: _stockExpanded,
                summary: _stockSummary(l10n),
                purchaseDate: _purchaseDate,
                now: now,
                hasCamera: caps.hasCamera,
                onMinStockChanged: () => setState(() {}),
                onStorageChanged: (value) => setState(
                  () => _storageLocationController.text = value ?? '',
                ),
                onPurchaseDateSelected: (date) =>
                    setState(() => _purchaseDate = date),
                onSearchBarcode: _searchBarcode,
                onScan: _openScanner,
                onBarcodeChanged: (value) => setState(() {
                  // Typed over the scanned code: the remembered EAN
                  // belongs to the pack that carried the old code.
                  if (value.trim() != _eanCode) {
                    _ean = null;
                    _eanCode = null;
                  }
                }),
                onBarcodeSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    _searchBarcode(value.trim());
                  }
                },
              ),
              const SizedBox(height: 12),

              // ── Details ──
              MedicationDetailsSection(
                descriptionController: _descriptionController,
                manufacturerController: _manufacturerController,
                atcCodeController: _atcCodeController,
                notesController: _notesController,
                expanded: _detailsExpanded,
                activeIngredients: _activeIngredients,
                onActiveIngredientsChanged: (tags) =>
                    setState(() => _activeIngredients = tags),
                symptoms: _symptoms,
                onSymptomsChanged: (tags) => setState(() => _symptoms = tags),
                patientTags: _patientTags,
                onPatientTagsChanged: (tags) =>
                    setState(() => _patientTags = tags),
                category: _selectedCategory,
                onCategoryChanged: (value) =>
                    setState(() => _selectedCategory = value),
                photo: kIsWeb
                    ? null
                    : MedicationPhotoSection(
                        imagePath: _imagePath,
                        onPick: _pickImage,
                        onDelete: _deletePhoto,
                      ),
              ),
              const SizedBox(height: 16),
            ],
          ),
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
                  : Text(
                      _isEditMode
                          ? l10n.updateMedication
                          : l10n.addMedicationButton,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// Drops the picked photo, deleting the file unless it is the one the
  /// saved medication still points at.
  Future<void> _deletePhoto() async {
    if (!_isEditMode || _imagePath != _existingMedication?.imagePath) {
      await ref.read(photoStorageProvider).delete(_imagePath);
    }
    if (!mounted) return;
    setState(() => _imagePath = null);
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
      ean: _ean,
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
