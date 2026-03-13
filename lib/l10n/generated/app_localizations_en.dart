// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Medora';

  @override
  String get navHome => 'Dashboard';

  @override
  String get navMedications => 'Medications';

  @override
  String get navDoses => 'Doses';

  @override
  String get navTreatments => 'Treatments';

  @override
  String get dashboard => 'Dashboard';

  @override
  String get seeAll => 'See All';

  @override
  String get todaysDoses => 'Today\'s Doses';

  @override
  String get noDosesScheduled => 'No doses scheduled for today';

  @override
  String dosesProgress(int taken, int total, int pending) {
    return '$taken of $total taken · $pending pending';
  }

  @override
  String get unableToLoadDoses => 'Unable to load doses';

  @override
  String get addMedication => 'Add\nMedication';

  @override
  String get scanBarcode => 'Scan\nBarcode';

  @override
  String get newTreatment => 'New\nTreatment';

  @override
  String get expiringSoon => 'Expiring Soon';

  @override
  String get lowStock => 'Low Stock';

  @override
  String get activeTreatments => 'Active Treatments';

  @override
  String get allMedicationsWithinDate => 'All medications are within date';

  @override
  String get allMedicationsWellStocked => 'All medications are well stocked';

  @override
  String get noActiveTreatments => 'No active treatments';

  @override
  String expiresInDays(int days) {
    return 'Expires in $days days';
  }

  @override
  String get noExpirySet => 'No expiry set';

  @override
  String remaining(int quantity) {
    return '$quantity remaining';
  }

  @override
  String startedOn(String date) {
    return 'Started $date';
  }

  @override
  String get medications => 'Medications';

  @override
  String get searchMedications => 'Search medications...';

  @override
  String get noMedicationsYet => 'No medications yet';

  @override
  String get addFirstMedication => 'Add your first medication to get started';

  @override
  String get addMedicationButton => 'Add Medication';

  @override
  String get edit => 'Edit';

  @override
  String get delete => 'Delete';

  @override
  String get deleteMedication => 'Delete Medication';

  @override
  String deleteMedicationConfirm(String name) {
    return 'Are you sure you want to delete \"$name\"?';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get noExpiry => 'No expiry';

  @override
  String get loadingMedications => 'Loading medications...';

  @override
  String get editMedication => 'Edit Medication';

  @override
  String get medicationNameLabel => 'Medication Name *';

  @override
  String get pleaseEnterMedicationName => 'Please enter a medication name';

  @override
  String get activeIngredient => 'Active Ingredient';

  @override
  String get category => 'Category';

  @override
  String get quantityLabel => 'Quantity *';

  @override
  String get required => 'Required';

  @override
  String get invalidNumber => 'Invalid number';

  @override
  String get minStock => 'Min Stock';

  @override
  String get purchaseDate => 'Purchase Date';

  @override
  String get expiryDate => 'Expiry Date';

  @override
  String get storageLocation => 'Storage Location';

  @override
  String get barcode => 'Barcode';

  @override
  String get notes => 'Notes';

  @override
  String get updateMedication => 'Update Medication';

  @override
  String get medicationUpdatedSuccessfully => 'Medication updated successfully';

  @override
  String get medicationAddedSuccessfully => 'Medication added successfully';

  @override
  String errorLoadingMedication(String message) {
    return 'Error loading medication: $message';
  }

  @override
  String get selectDate => 'Select date';

  @override
  String get medication => 'Medication';

  @override
  String get medicationNotFound => 'Medication not found';

  @override
  String get quantity => 'Quantity';

  @override
  String get details => 'Details';

  @override
  String get minimumStock => 'Minimum Stock';

  @override
  String get expired => 'Expired';

  @override
  String expiresInDaysShort(int days) {
    return 'Expires in $days days';
  }

  @override
  String get valid => 'Valid';

  @override
  String quantityLeft(int quantity) {
    return '$quantity left';
  }

  @override
  String get treatments => 'Treatments';

  @override
  String get noTreatmentsYet => 'No treatments yet';

  @override
  String get createTreatmentPlan => 'Create a treatment plan for an illness';

  @override
  String get addTreatment => 'Add Treatment';

  @override
  String get end => 'End';

  @override
  String get deleteTreatment => 'Delete Treatment';

  @override
  String deleteTreatmentConfirm(String name) {
    return 'Delete \"$name\" and all its prescriptions?';
  }

  @override
  String get active => 'Active';

  @override
  String get ended => 'Ended';

  @override
  String get loadingTreatments => 'Loading treatments...';

  @override
  String get newTreatmentTitle => 'New Treatment';

  @override
  String get treatmentNameLabel => 'Treatment Name *';

  @override
  String get treatmentNameHint => 'e.g., Flu Treatment';

  @override
  String get pleaseEnterTreatmentName => 'Please enter a treatment name';

  @override
  String get symptoms => 'Symptoms';

  @override
  String get symptomsHint => 'e.g., Fever, headache, sore throat';

  @override
  String get startDateLabel => 'Start Date *';

  @override
  String get endDateLabel => 'End Date (optional)';

  @override
  String get selectEndDate => 'Select end date';

  @override
  String get createTreatment => 'Create Treatment';

  @override
  String get treatmentCreatedSuccessfully => 'Treatment created successfully';

  @override
  String get treatment => 'Treatment';

  @override
  String get treatmentNotFound => 'Treatment not found';

  @override
  String get endTreatment => 'End Treatment';

  @override
  String endTreatmentConfirm(String name) {
    return 'End \"$name\"? This will deactivate all prescriptions.';
  }

  @override
  String get startDate => 'Start Date';

  @override
  String get endDate => 'End Date';

  @override
  String get ongoing => 'Ongoing';

  @override
  String get prescriptions => 'Prescriptions';

  @override
  String numPrescriptions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count prescriptions',
      one: '1 prescription',
      zero: 'No prescriptions',
    );
    return '$_temp0';
  }

  @override
  String get add => 'Add';

  @override
  String get noPrescriptionsYet => 'No prescriptions yet';

  @override
  String get addPrescription => 'Add Prescription';

  @override
  String get unknownMedication => 'Unknown Medication';

  @override
  String prescriptionSummary(String dosage, int hours, int days) {
    return '$dosage · every ${hours}h · $days days';
  }

  @override
  String get done => 'Done';

  @override
  String errorLoadingPrescriptions(String message) {
    return 'Error loading prescriptions: $message';
  }

  @override
  String get medicationLabel => 'Medication *';

  @override
  String get dosageLabel => 'Dosage *';

  @override
  String get dosageHint => 'e.g., 400mg';

  @override
  String get intervalHoursLabel => 'Interval (hours)';

  @override
  String get durationDaysLabel => 'Duration (days)';

  @override
  String get todaysDosesTitle => 'Today\'s Doses';

  @override
  String get noDosesScheduledToday => 'No doses scheduled for today';

  @override
  String get createTreatmentForDoses =>
      'Create a treatment and add prescriptions to see doses here';

  @override
  String get upcoming => 'Upcoming';

  @override
  String get completed => 'Completed';

  @override
  String get taken => 'Taken';

  @override
  String takenAt(String time) {
    return 'Taken at $time';
  }

  @override
  String get pending => 'Pending';

  @override
  String get skipped => 'Skipped';

  @override
  String get missed => 'Missed';

  @override
  String get overdue => 'Overdue';

  @override
  String get skip => 'Skip';

  @override
  String get take => 'Take';

  @override
  String get loadingDoses => 'Loading doses...';

  @override
  String get scanBarcodeTitle => 'Scan AIC Code';

  @override
  String get pointCameraAtBarcode => 'Point camera at AIC code on package';

  @override
  String get enterBarcodeManually => 'Enter code manually';

  @override
  String get enterBarcode => 'Enter AIC Code';

  @override
  String get barcodeNumber => 'AIC code';

  @override
  String get barcodeHint => 'e.g., A023834118';

  @override
  String get useBarcode => 'Search';

  @override
  String get scanBarcodeTooltip => 'Scan AIC Code';

  @override
  String get ocrDetectedCodes => 'Detected codes — tap to search';

  @override
  String get ocrScanning => 'Scanning for AIC codes…';

  @override
  String get settings => 'Settings';

  @override
  String get about => 'About';

  @override
  String get appVersion => 'Version';

  @override
  String get colorScheme => 'Color Scheme';

  @override
  String get colorSchemeDesc => 'Choose an accent color for the app';

  @override
  String get colorTeal => 'Teal';

  @override
  String get colorBlue => 'Blue';

  @override
  String get colorIndigo => 'Indigo';

  @override
  String get colorPurple => 'Purple';

  @override
  String get colorPink => 'Pink';

  @override
  String get colorRed => 'Red';

  @override
  String get colorOrange => 'Orange';

  @override
  String get colorGreen => 'Green';

  @override
  String get aifaDatabase => 'AIFA Database';

  @override
  String get aifaDatabaseDesc => 'Italian medication database for code lookup';

  @override
  String aifaLastSync(String date) {
    return 'Last sync: $date';
  }

  @override
  String get aifaNeverSynced => 'Not yet downloaded';

  @override
  String get aifaSyncing => 'Downloading database…';

  @override
  String aifaSyncSuccess(int count) {
    return 'Database updated ($count medications)';
  }

  @override
  String get aifaSyncError => 'Failed to download database';

  @override
  String get syncAifaDatabase => 'Update Database';

  @override
  String get notifications => 'Notifications';

  @override
  String get enableNotifications => 'Enable Notifications';

  @override
  String get receiveDoseReminders => 'Receive dose reminders';

  @override
  String get cancelAllReminders => 'Cancel All Reminders';

  @override
  String get removePendingNotifications => 'Remove all pending notifications';

  @override
  String get cancelAllRemindersConfirm =>
      'Are you sure you want to cancel all pending reminders?';

  @override
  String get no => 'No';

  @override
  String get yes => 'Yes';

  @override
  String get allRemindersCancelled => 'All reminders cancelled';

  @override
  String get dataAndSync => 'Data & Sync';

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get connectedSyncsAutomatically =>
      'Connected — data syncs automatically';

  @override
  String get usingLocalData => 'Using local data — will sync when online';

  @override
  String get syncNow => 'Sync Now';

  @override
  String get syncIdle => 'Tap to sync data with the cloud';

  @override
  String get syncing => 'Syncing...';

  @override
  String get syncSuccess => 'Sync completed successfully';

  @override
  String get syncError => 'Sync failed — tap to retry';

  @override
  String get features => 'Features';

  @override
  String get familySharing => 'Family Sharing';

  @override
  String get shareCabinetWithFamily =>
      'Share your medicine cabinet with family';

  @override
  String get exportData => 'Export Data';

  @override
  String get exportAsCsvOrPdf => 'Export as CSV or PDF';

  @override
  String get exportDataTitle => 'Export Data';

  @override
  String get exportYourData => 'Export Your Data';

  @override
  String get chooseWhatToExport => 'Choose what to export and the format';

  @override
  String get include => 'Include';

  @override
  String get fullMedicationInventory => 'Full medication inventory';

  @override
  String get treatmentPlansAndHistory => 'Treatment plans and history';

  @override
  String get doseLogs => 'Dose Logs';

  @override
  String get medicationIntakeRecords => 'Medication intake records';

  @override
  String get doseLogDateRange => 'Dose Log Date Range';

  @override
  String get from => 'From';

  @override
  String get to => 'To';

  @override
  String get format => 'Format';

  @override
  String get exporting => 'Exporting...';

  @override
  String get exportAndShare => 'Export & Share';

  @override
  String get noDataToExport => 'No data to export';

  @override
  String exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get familySharingTitle => 'Family Sharing';

  @override
  String get loadingFamily => 'Loading family...';

  @override
  String get noFamilyGroup => 'No Family Group';

  @override
  String get noFamilyDescription =>
      'Create a family group to share your medicine cabinet, or join an existing one with an invite code.';

  @override
  String get createFamily => 'Create Family';

  @override
  String get joinWithCode => 'Join with Code';

  @override
  String get familyName => 'Family Name';

  @override
  String get familyNameHint => 'e.g., Smith Family';

  @override
  String get yourName => 'Your Name';

  @override
  String get yourNameHint => 'e.g., John';

  @override
  String get create => 'Create';

  @override
  String get joinFamily => 'Join Family';

  @override
  String get inviteCode => 'Invite Code';

  @override
  String get inviteCodeHint => 'e.g., ABC123';

  @override
  String get join => 'Join';

  @override
  String get copyCode => 'Copy code';

  @override
  String get codeCopied => 'Code copied to clipboard';

  @override
  String get shareCode => 'Share code';

  @override
  String joinMedoraFamily(String code) {
    return 'Join my Medora family! Use code: $code';
  }

  @override
  String get generateNewCode => 'Generate New Code';

  @override
  String get members => 'Members';

  @override
  String get noMembersYet => 'No members yet';

  @override
  String get unknown => 'Unknown';

  @override
  String get owner => 'Owner';

  @override
  String get member => 'Member';

  @override
  String get removeMember => 'Remove Member';

  @override
  String removeMemberConfirm(String name) {
    return 'Remove $name from the family?';
  }

  @override
  String get remove => 'Remove';

  @override
  String get leaveFamily => 'Leave Family';

  @override
  String get leaveFamilyConfirm =>
      'Are you sure you want to leave this family? You will no longer have access to shared medications.';

  @override
  String get leave => 'Leave';

  @override
  String get retry => 'Retry';

  @override
  String error(String message) {
    return 'Error: $message';
  }

  @override
  String get appearance => 'Appearance';

  @override
  String get darkMode => 'Dark Mode';

  @override
  String get darkModeLabel => 'Dark';

  @override
  String get lightMode => 'Light';

  @override
  String get systemDefault => 'System';

  @override
  String get language => 'Language';

  @override
  String get lookingUpBarcode => 'Looking up barcode…';

  @override
  String get autoFilledFromBarcode => 'Product found — fields auto-filled';

  @override
  String get barcodeNotFound => 'Product not found — enter details manually';

  @override
  String get editTreatment => 'Edit Treatment';

  @override
  String get treatmentUpdatedSuccessfully => 'Treatment updated successfully';

  @override
  String get updateTreatment => 'Update Treatment';

  @override
  String get editPrescription => 'Edit Prescription';

  @override
  String get prescriptionUpdated => 'Prescription updated';

  @override
  String get scheduleType => 'Schedule Type';

  @override
  String get fixedInterval => 'Fixed Interval';

  @override
  String get timesPerDay => 'Times per Day';

  @override
  String get specificTimes => 'Specific Times';

  @override
  String get morning => 'Morning';

  @override
  String get noon => 'Noon';

  @override
  String get evening => 'Evening';

  @override
  String get beforeSleep => 'Before Sleep';

  @override
  String get selectTimes => 'Select Times';

  @override
  String everyXHours(int hours) {
    return 'Every $hours hours';
  }

  @override
  String xTimesDaily(int count) {
    return '$count times daily';
  }

  @override
  String get save => 'Save';

  @override
  String get update => 'Update';

  @override
  String get selectMedication => 'Select Medication';

  @override
  String get results => 'results';

  @override
  String get searchByBarcode => 'Search by code';

  @override
  String get archiveTreatment => 'Archive Treatment';

  @override
  String archiveTreatmentConfirm(String name) {
    return 'Archive \"$name\"? It will be moved to the archive and can be viewed later.';
  }

  @override
  String get archive => 'Archive';

  @override
  String get archived => 'Archived';

  @override
  String get deletePrescription => 'Delete Prescription';

  @override
  String get deletePrescriptionConfirm =>
      'Are you sure you want to delete this prescription? This action cannot be undone.';

  @override
  String get prescriptionDeleted => 'Prescription deleted';

  @override
  String get patientName => 'Patient';

  @override
  String get patientNameHint => 'e.g. Baby, Mom...';

  @override
  String get doseHistory => 'Dose History';

  @override
  String get noDoseHistory => 'No dose history yet';

  @override
  String get medicationPhoto => 'Photo';

  @override
  String get addPhoto => 'Add Photo';

  @override
  String get changePhoto => 'Change Photo';

  @override
  String get photoSource => 'Photo Source';

  @override
  String get camera => 'Camera';

  @override
  String get gallery => 'Gallery';

  @override
  String forPatient(String name) {
    return 'For: $name';
  }

  @override
  String get catPainkiller => 'Painkiller';

  @override
  String get catAntibiotic => 'Antibiotic';

  @override
  String get catAntihistamine => 'Antihistamine';

  @override
  String get catVitamin => 'Vitamin';

  @override
  String get catSupplement => 'Supplement';

  @override
  String get catColdFlu => 'Cold & Flu';

  @override
  String get catDigestive => 'Digestive';

  @override
  String get catSkinCare => 'Skin Care';

  @override
  String get catEyeCare => 'Eye Care';

  @override
  String get catFirstAid => 'First Aid';

  @override
  String get catOther => 'Other';

  @override
  String get activeIngredients => 'Active Ingredients';

  @override
  String get symptomsField => 'Symptoms / Used For';

  @override
  String get patientTagsField => 'Patient';

  @override
  String get addTag => 'Add tag...';

  @override
  String get treatsSymptoms => 'Treats';

  @override
  String get uncategorized => 'Uncategorized';

  @override
  String get deactivatePrescription => 'Deactivate';

  @override
  String get prescriptionDeactivated => 'Prescription deactivated';

  @override
  String get reactivatePrescription => 'Reactivate';

  @override
  String get prescriptionReactivated => 'Prescription reactivated';

  @override
  String get locMedicineCabinet => 'Medicine Cabinet';

  @override
  String get locBathroom => 'Bathroom';

  @override
  String get locKitchen => 'Kitchen';

  @override
  String get locBedroom => 'Bedroom';

  @override
  String get locRefrigerator => 'Refrigerator';

  @override
  String get locFirstAidKit => 'First Aid Kit';

  @override
  String get locOther => 'Other';

  @override
  String get deleteAllData => 'Delete All Data';

  @override
  String get deleteAllDataDesc =>
      'Remove all medications, treatments, doses and prescriptions';

  @override
  String get deleteAllDataConfirm =>
      'This will permanently delete ALL your data locally and online. Type DELETE to confirm.';

  @override
  String get typeDeleteToConfirm => 'Type DELETE to confirm';

  @override
  String get allDataDeleted => 'All data has been deleted';

  @override
  String get dangerZone => 'Danger Zone';

  @override
  String get treatmentPatientTags => 'Patient';

  @override
  String get treatmentSymptomTags => 'Symptoms';

  @override
  String get searchTreatments => 'Search treatments…';

  @override
  String get all => 'All';

  @override
  String get noResults => 'No results found';

  @override
  String get medicationDescription => 'Description';

  @override
  String get manufacturerLabel => 'Manufacturer';

  @override
  String get formLabel => 'Form';

  @override
  String get atcCodeLabel => 'ATC Code';

  @override
  String get searchAifaByName => 'Search AIFA Database';

  @override
  String get quantityUnit => 'Unit';

  @override
  String get unitPieces => 'Pieces';

  @override
  String get unitPills => 'Pills';

  @override
  String get unitTablets => 'Tablets';

  @override
  String get unitCapsules => 'Capsules';

  @override
  String get unitMl => 'ml';

  @override
  String get unitDrops => 'Drops';

  @override
  String get unitBustine => 'Sachets';

  @override
  String get unitAmpoules => 'Ampoules';

  @override
  String get unitSuppositories => 'Suppositories';

  @override
  String get unitPatches => 'Patches';

  @override
  String get autoDiminish => 'Auto-decrease stock';

  @override
  String get autoDiminishHint =>
      'Automatically reduce medication quantity when a dose is taken';

  @override
  String get unarchive => 'Unarchive';

  @override
  String get archivedMedications => 'Archived Medications';

  @override
  String get showArchived => 'Show archived';

  @override
  String get signIn => 'Sign In';

  @override
  String get signUp => 'Sign Up';

  @override
  String get createAccount => 'Create Account';

  @override
  String get email => 'Email';

  @override
  String get password => 'Password';

  @override
  String get continueAsGuest => 'Continue as Guest';

  @override
  String get signOut => 'Sign Out';

  @override
  String get alreadyHaveAccount => 'Already have an account? Sign In';

  @override
  String get dontHaveAccount => 'Don\'t have an account? Sign Up';

  @override
  String get useOfflineMode => 'Use Offline Mode';

  @override
  String get forcePush => 'Force Push';

  @override
  String get forcePull => 'Force Pull';

  @override
  String get forcePushTitle => 'Force Push to Cloud';

  @override
  String get forcePullTitle => 'Force Pull from Cloud';

  @override
  String get forcePushConfirm =>
      'This will overwrite all data in Supabase with your local data. This action cannot be undone. Continue?';

  @override
  String get forcePullConfirm =>
      'This will overwrite all your local data with data from Supabase. Any unsynced local changes will be lost. Continue?';

  @override
  String get continueLabel => 'Continue';

  @override
  String get daysLabel => 'Days';

  @override
  String get leftLabel => 'Left';

  @override
  String get notificationChannelName => 'Dose Reminders';

  @override
  String get notificationChannelDescription =>
      'Reminders for scheduled medication doses';

  @override
  String get notificationTicker => 'Medication Reminder';

  @override
  String notificationReminderTimeFor(String medication) {
    return 'Time for $medication';
  }

  @override
  String notificationReminderInMinutes(String medication, int minutes) {
    return 'Reminder: $medication in $minutes min';
  }

  @override
  String notificationReminderBody(String dosage) {
    return '$dosage — Tap to log your dose';
  }
}
