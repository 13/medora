/// Medora - Add/Edit Medication Screen
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:medora/core/constants.dart';
import 'package:medora/core/supabase_config.dart';
import 'package:medora/data/datasources/barcode_lookup_datasource.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/l10n/generated/app_localizations.dart';
import 'package:medora/presentation/providers/medication_providers.dart';
import 'package:medora/presentation/providers/providers.dart';
import 'package:medora/presentation/router/app_router.dart';
import 'package:medora/services/aifa_cache_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
    _minStockController = TextEditingController(text: '5');
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
      },
      failure: (msg) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.errorLoadingMedication(msg))),
        );
      },
    );
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
      AifaSearchResult? selected;
      if (results.length == 1) {
        selected = results.first;
      } else {
        selected = await showModalBottomSheet<AifaSearchResult>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => DraggableScrollableSheet(
            initialChildSize: 0.5,
            minChildSize: 0.3,
            maxChildSize: 0.85,
            expand: false,
            builder: (ctx, scrollCtrl) => Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    l10n.selectMedication,
                    style: Theme.of(ctx).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    controller: scrollCtrl,
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final r = results[i];
                      return ListTile(
                        title: Text(r.name,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.description,
                                style: const TextStyle(fontSize: 12),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            if (r.activeIngredient != null)
                              Text(r.activeIngredient!,
                                  style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                          ],
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(ctx, r),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      }

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
    final searchController = TextEditingController();
    List<AifaSearchResult> results = [];
    bool isSearching = false;

    final selected = await showModalBottomSheet<AifaSearchResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (ctx, scrollController) => Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.searchAifaByName,
                  style: Theme.of(ctx)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: l10n.searchMedications,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: isSearching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: const Icon(Icons.send),
                            onPressed: () async {
                              final query =
                                  searchController.text.trim();
                              if (query.length < 2) return;
                              setSheetState(() => isSearching = true);
                              try {
                                final r = await AifaCacheService.instance
                                    .searchByName(query);
                                setSheetState(() {
                                  results = r;
                                  isSearching = false;
                                });
                              } catch (_) {
                                setSheetState(
                                    () => isSearching = false);
                              }
                            },
                          ),
                  ),
                  onSubmitted: (query) async {
                    if (query.trim().length < 2) return;
                    setSheetState(() => isSearching = true);
                    try {
                      final r = await AifaCacheService.instance
                          .searchByName(query.trim());
                      setSheetState(() {
                        results = r;
                        isSearching = false;
                      });
                    } catch (_) {
                      setSheetState(() => isSearching = false);
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Expanded(
                child: results.isEmpty
                    ? Center(
                        child: Text(
                          isSearching
                              ? ''
                              : l10n.searchMedications,
                          style: TextStyle(color: Colors.grey[400]),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: results.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final r = results[i];
                          return ListTile(
                            title: Text(r.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                if (r.description.isNotEmpty)
                                  Text(r.description,
                                      style:
                                          const TextStyle(fontSize: 12),
                                      maxLines: 2,
                                      overflow:
                                          TextOverflow.ellipsis),
                                if (r.activeIngredient != null)
                                  Text(r.activeIngredient!,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey[600])),
                                if (r.manufacturer != null)
                                  Text(r.manufacturer!,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey[500])),
                              ],
                            ),
                            trailing:
                                const Icon(Icons.chevron_right),
                            onTap: () =>
                                Navigator.pop(ctx, r),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: l10n.scanBarcodeTooltip,
              onPressed: () async {
                final barcode = await context.push<String>(AppRoutes.scanner);
                if (barcode != null && mounted) {
                  setState(() => _barcodeController.text = barcode);
                }
              },
            ),
          ],
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Name
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.medicationNameLabel,
                prefixIcon: const Icon(Icons.medication),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.pleaseEnterMedicationName;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Description (e.g. "400 MG COMPRESSE RIVESTITE- 30 COMPRESSE IN BLISTER")
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: l10n.medicationDescription,
                prefixIcon: const Icon(Icons.description),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),

            // Active Ingredients (tags)
            _TagInputField(
              label: l10n.activeIngredients,
              icon: Icons.science,
              tags: _activeIngredients,
              onChanged: (tags) => setState(() => _activeIngredients = tags),
            ),
            const SizedBox(height: 16),

            // Symptoms / Used For (tags)
            _TagInputField(
              label: l10n.symptomsField,
              icon: Icons.local_hospital,
              tags: _symptoms,
              onChanged: (tags) => setState(() => _symptoms = tags),
            ),
            const SizedBox(height: 16),

            // Patient (tags) — e.g. "Baby", "Mom"
            _TagInputField(
              label: l10n.patientTagsField,
              icon: Icons.person,
              tags: _patientTags,
              onChanged: (tags) => setState(() => _patientTags = tags),
            ),
            const SizedBox(height: 16),

            // Category Dropdown (localized)
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
              onChanged: (value) => setState(() => _selectedCategory = value),
            ),
            const SizedBox(height: 16),

            // Manufacturer
            TextFormField(
              controller: _manufacturerController,
              decoration: InputDecoration(
                labelText: l10n.manufacturerLabel,
                prefixIcon: const Icon(Icons.factory),
              ),
            ),
            const SizedBox(height: 16),

            // Form & ATC row
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _formController,
                    decoration: InputDecoration(
                      labelText: l10n.formLabel,
                      prefixIcon: const Icon(Icons.medical_information),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _atcCodeController,
                    decoration: InputDecoration(
                      labelText: l10n.atcCodeLabel,
                      prefixIcon: const Icon(Icons.code),
                    ),
                    textCapitalization: TextCapitalization.characters,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Quantity, Unit & Min Stock
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
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return l10n.required;
                      }
                      if (int.tryParse(value) == null) {
                        return l10n.invalidNumber;
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('unit_$_quantityUnit'),
                    initialValue: _quantityUnit,
                    decoration: InputDecoration(
                      labelText: l10n.quantityUnit,
                      prefixIcon: const Icon(Icons.straighten),
                    ),
                    items: [
                      DropdownMenuItem(value: 'pieces', child: Text(l10n.unitPieces)),
                      DropdownMenuItem(value: 'pills', child: Text(l10n.unitPills)),
                      DropdownMenuItem(value: 'tablets', child: Text(l10n.unitTablets)),
                      DropdownMenuItem(value: 'capsules', child: Text(l10n.unitCapsules)),
                      DropdownMenuItem(value: 'ml', child: Text(l10n.unitMl)),
                      DropdownMenuItem(value: 'drops', child: Text(l10n.unitDrops)),
                      DropdownMenuItem(value: 'bustine', child: Text(l10n.unitBustine)),
                      DropdownMenuItem(value: 'ampoules', child: Text(l10n.unitAmpoules)),
                      DropdownMenuItem(value: 'suppositories', child: Text(l10n.unitSuppositories)),
                      DropdownMenuItem(value: 'patches', child: Text(l10n.unitPatches)),
                    ],
                    onChanged: (v) => setState(() => _quantityUnit = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _minStockController,
              decoration: InputDecoration(
                labelText: l10n.minStock,
                prefixIcon: const Icon(Icons.low_priority),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),

            // Purchase Date
            _DatePickerField(
              label: l10n.purchaseDate,
              icon: Icons.shopping_cart,
              date: _purchaseDate,
              onDateSelected: (date) =>
                  setState(() => _purchaseDate = date),
            ),
            const SizedBox(height: 16),

            // Expiry Date
            _DatePickerField(
              label: l10n.expiryDate,
              icon: Icons.event,
              date: _expiryDate,
              onDateSelected: (date) =>
                  setState(() => _expiryDate = date),
            ),
            const SizedBox(height: 16),

            // Storage Location
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
                _storageLocationController.text = value ?? '';
              },
            ),
            const SizedBox(height: 16),

            // Barcode
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
                          ? () => _searchBarcode(_barcodeController.text.trim())
                          : null,
                    ),
                    // Open camera scanner
                    IconButton(
                      icon: const Icon(Icons.qr_code_scanner),
                      onPressed: () async {
                        final barcode = await context
                            .push<String>('${AppRoutes.scanner}?returnOnly=true');
                        if (barcode != null && mounted) {
                          setState(() => _barcodeController.text = barcode);
                          _searchBarcode(barcode);
                        }
                      },
                    ),
                  ],
                ),
              ),
              onFieldSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  _searchBarcode(value.trim());
                }
              },
            ),
            const SizedBox(height: 16),

            // Photo
            _buildPhotoSection(l10n),
            const SizedBox(height: 16),

            // Notes
            TextFormField(
              controller: _notesController,
              decoration: InputDecoration(
                labelText: l10n.notes,
                prefixIcon: const Icon(Icons.notes),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 32),

            // Save Button
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _saveMedication,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : Text(_isEditMode
                        ? l10n.updateMedication
                        : l10n.addMedicationButton),
              ),
            ),
            const SizedBox(height: 16),
          ],
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
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: _imagePath != null && File(_imagePath!).existsSync()
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(File(_imagePath!),
                        fit: BoxFit.cover, width: double.infinity),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo,
                          size: 40, color: Colors.grey[400]),
                      const SizedBox(height: 8),
                      Text(l10n.addPhoto,
                          style: TextStyle(color: Colors.grey[500])),
                    ],
                  ),
          ),
        ),
        if (_imagePath != null) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _imagePath = null),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(l10n.delete),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickImage() async {
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

    // Save to app documents directory
    final dir = await getApplicationDocumentsDirectory();
    final ext = p.extension(picked.path);
    final fileName = 'med_${const Uuid().v4()}$ext';
    final savedPath = p.join(dir.path, 'medication_photos', fileName);
    await Directory(p.dirname(savedPath)).create(recursive: true);
    await File(picked.path).copy(savedPath);

    setState(() => _imagePath = savedPath);
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
      minimumStockLevel: int.tryParse(_minStockController.text) ?? 5,
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
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

/// Reusable date picker form field.
class _DatePickerField extends StatelessWidget {
  const _DatePickerField({
    required this.label,
    required this.icon,
    required this.date,
    required this.onDateSelected,
  });

  final String label;
  final IconData icon;
  final DateTime? date;
  final ValueChanged<DateTime?> onDateSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) {
          onDateSelected(picked);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: date != null
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => onDateSelected(null),
                )
              : null,
        ),
        child: Text(
          date != null
              ? '${date!.year}-${date!.month.toString().padLeft(2, '0')}-${date!.day.toString().padLeft(2, '0')}'
              : l10n.selectDate,
          style: TextStyle(
            color: date != null ? null : Colors.grey[500],
          ),
        ),
      ),
    );
  }
}

/// Reusable tag input field for entering multiple tags (chips).
class _TagInputField extends StatefulWidget {
  const _TagInputField({
    required this.label,
    required this.icon,
    required this.tags,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_TagInputField> createState() => _TagInputFieldState();
}

class _TagInputFieldState extends State<_TagInputField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  void _addTag(String text) {
    final tag = text.trim();
    if (tag.isNotEmpty && !widget.tags.contains(tag)) {
      widget.onChanged([...widget.tags, tag]);
    }
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: widget.tags.map((tag) {
                return Chip(
                  label: Text(tag, style: const TextStyle(fontSize: 13)),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () {
                    widget.onChanged(
                        widget.tags.where((t) => t != tag).toList());
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          decoration: InputDecoration(
            labelText: widget.label,
            prefixIcon: Icon(widget.icon),
            hintText: l10n.addTag,
            suffixIcon: IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => _addTag(_controller.text),
            ),
          ),
          onSubmitted: (value) {
            _addTag(value);
            _focusNode.requestFocus();
          },
        ),
      ],
    );
  }
}
