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
  String get appDescription => 'Medora - Home Medicine Cabinet Manager';

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
  String moreCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more',
      one: '1 more',
    );
    return '$_temp0';
  }

  @override
  String get todaysDoses => 'Today\'s Doses';

  @override
  String get noDosesScheduled => 'No doses scheduled for today';

  @override
  String dosesProgress(int taken, int total, int pending) {
    return '$taken of $total taken · $pending pending';
  }

  @override
  String get addMedication => 'Add\nMedication';

  @override
  String get scanBarcode => 'Scan\nBarcode';

  @override
  String get newTreatment => 'New\nTreatment';

  @override
  String get expiringSoon => 'Expiring Soon';

  @override
  String get expiringOrExpired => 'Expired & Expiring';

  @override
  String get lowStock => 'Low Stock';

  @override
  String get activeTreatments => 'Active Treatments';

  @override
  String get statExpiring => 'Expiry';

  @override
  String get statLowStock => 'Low stock';

  @override
  String get statTreatments => 'Treatments';

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
  String get searchMedications => 'Search medications…';

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
  String get sectionBasics => 'Basics';

  @override
  String get sectionStock => 'Stock & storage';

  @override
  String get sectionDetails => 'Details';

  @override
  String minStockShort(int n) {
    return 'min $n';
  }

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
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Expires in $days days',
      one: 'Expires in 1 day',
      zero: 'Expires today',
    );
    return '$_temp0';
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
    return 'End \"$name\"? No new doses or reminders will be created for its medicines, and no further doses can be logged. Doses already recorded are kept.';
  }

  @override
  String get endTreatmentFailed => 'Could not end the treatment';

  @override
  String get startDate => 'Start Date';

  @override
  String get endDate => 'End Date';

  @override
  String get ongoing => 'Ongoing';

  @override
  String get ongoingInline => 'ongoing';

  @override
  String get sickLeave => 'Sick leave';

  @override
  String get sickLeaveFrom => 'Unable to work from';

  @override
  String get sickLeaveTo => 'Unable to work until';

  @override
  String sickLeaveDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String sickLeaveDay(int days) {
    return 'Day $days';
  }

  @override
  String get sickLeaveDuration => 'Duration';

  @override
  String get sickLeaveRef => 'Certificate no.';

  @override
  String get sickLeaveRefHint => 'e.g. 1234567890';

  @override
  String sickLeaveToBeforeFrom(String to, String from) {
    return '\"$to\" can\'t be before \"$from\"';
  }

  @override
  String sickLeaveFromMissing(String from) {
    return 'Please also enter \"$from\"';
  }

  @override
  String sickLeaveEndToday(String date) {
    return 'Also end sick leave today (until $date)';
  }

  @override
  String get doctorLabel => 'Doctor';

  @override
  String get doctorHint => 'e.g. Dr. Rossi, Bolzano';

  @override
  String get illness => 'Illness';

  @override
  String get sickLeavePeriod => 'Sick leave';

  @override
  String dosesTakenOfPlanned(int taken, int total) {
    return '$taken of $total taken';
  }

  @override
  String dosesTakenAsNeeded(int taken) {
    String _temp0 = intl.Intl.pluralLogic(
      taken,
      locale: localeName,
      other: '$taken doses taken',
      one: '1 dose taken',
      zero: 'Not taken',
    );
    return '$_temp0';
  }

  @override
  String get shareEpisode => 'Share record';

  @override
  String episodeShareSubject(String period) {
    return 'Illness record: $period';
  }

  @override
  String get episodePatient => 'Patient';

  @override
  String dosageUnitName(num count, String unit) {
    String _temp0 = intl.Intl.selectLogic(unit, {
      'pieces': 'pieces',
      'pills': 'pills',
      'tablets': 'tablets',
      'capsules': 'capsules',
      'ml': 'ml',
      'drops': 'drops',
      'bustine': 'sachets',
      'ampoules': 'ampoules',
      'suppositories': 'suppositories',
      'patches': 'patches',
      'other': '$unit',
    });
    String _temp1 = intl.Intl.selectLogic(unit, {
      'pieces': 'piece',
      'pills': 'pill',
      'tablets': 'tablet',
      'capsules': 'capsule',
      'ml': 'ml',
      'drops': 'drop',
      'bustine': 'sachet',
      'ampoules': 'ampoule',
      'suppositories': 'suppository',
      'patches': 'patch',
      'other': '$unit',
    });
    String _temp2 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$_temp0',
      one: '$_temp1',
    );
    return '$_temp2';
  }

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
  String doseTimesPreview(String times) {
    return 'Doses at $times';
  }

  @override
  String get changeMedicationConfirm =>
      'Changing the medication regenerates pending doses. Continue?';

  @override
  String get intervalRange => 'Interval must be between 1 and 48 hours';

  @override
  String get durationRange => 'Duration must be between 1 and 365 days';

  @override
  String get selectAtLeastOneTime => 'Select at least one time';

  @override
  String get todaysDosesTitle => 'Today\'s Doses';

  @override
  String get noDosesScheduledToday => 'No doses scheduled for today';

  @override
  String get noDosesForThisDay => 'No doses on this day';

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
  String get nextDose => 'Next dose';

  @override
  String get allDosesDone => 'All doses done for today';

  @override
  String get doseTaken => 'Taken';

  @override
  String get doseSkipped => 'Skipped';

  @override
  String get undo => 'Undo';

  @override
  String get takeAllDue => 'Take all due';

  @override
  String dosesDueNow(int count) {
    return '$count doses due';
  }

  @override
  String dosesTakenCount(int count) {
    return '$count doses taken';
  }

  @override
  String get scanBarcodeTitle => 'Scan AIC Code';

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
  String get scanTakePhoto => 'Take photo';

  @override
  String get scanFromGallery => 'Choose from gallery';

  @override
  String get scanRetake => 'Retake';

  @override
  String get scanRecognizing => 'Reading text…';

  @override
  String get scanChooseCode => 'Tap the code to use';

  @override
  String get scanAicCodes => 'AIC codes';

  @override
  String get scanSupplementCodes => 'Supplement codes (Ministry of Health)';

  @override
  String get scanBarcodes => 'Barcodes (EAN)';

  @override
  String get scanOtherNumbers => 'Other numbers';

  @override
  String get scanNoCodeFound =>
      'No code found. Retake the photo closer, or type the code.';

  @override
  String get scanSelectArea => 'Select area';

  @override
  String get scanSelectCentre => 'Select the centre';

  @override
  String get scanRescanArea => 'Scan selection';

  @override
  String get scanSelectAreaHint =>
      'Drag a box around the code, then scan the selection.';

  @override
  String get scanRescanNothingNew => 'No new code found in that area.';

  @override
  String get scanRescanTooSmall =>
      'That selection is too small to scan. Draw a bigger box.';

  @override
  String get scanCaptureHint => 'Photograph the pack so the AIC code is sharp';

  @override
  String get scanMedicationInCabinet => 'Already in your cabinet';

  @override
  String get supplementRegister => 'Food supplement register';

  @override
  String get supplementRegisterHint =>
      'Ministry of Health register for supplement codes (COD MINSAN)';

  @override
  String supplementRegisterUpdated(String date) {
    return 'Register as of $date';
  }

  @override
  String get supplementRegisterUpdate => 'Update register';

  @override
  String get supplementRegisterDownload => 'Download';

  @override
  String registerStale(int days) {
    return 'Last updated $days days ago';
  }

  @override
  String get registerStaleUnknown => 'Age unknown — update recommended';

  @override
  String get registerUpdateNow => 'Update now';

  @override
  String get supplementRegisterDownloading => 'Downloading register…';

  @override
  String supplementRegisterSyncSuccess(int count) {
    return 'Register updated ($count products)';
  }

  @override
  String get supplementRegisterDownloadPrompt =>
      'Supplement codes are looked up in the Ministry of Health register. Download it now (about 2 MB)? An internet connection is required.';

  @override
  String get supplementNotFound =>
      'Supplement not found in the register — enter details manually';

  @override
  String get supplementSelectProduct => 'Select product';

  @override
  String scanAlternativeCodeConfirm(
    String read,
    String code,
    String product,
    String company,
  ) {
    return 'Code $read was not found. Did you mean $code: $product ($company)?';
  }

  @override
  String scanAlternativeCodeConfirmNoCompany(
    String read,
    String code,
    String product,
  ) {
    return 'Code $read was not found. Did you mean $code: $product?';
  }

  @override
  String get scanAlternativeCodeUse => 'Use';

  @override
  String get settings => 'Settings';

  @override
  String get about => 'About';

  @override
  String get appVersion => 'Version';

  @override
  String get buildNumber => 'Build';

  @override
  String get buildDate => 'Built';

  @override
  String get buildCommit => 'Commit';

  @override
  String get buildChannel => 'Channel';

  @override
  String get channelRelease => 'Release';

  @override
  String get channelCi => 'CI';

  @override
  String get channelDev => 'Development build';

  @override
  String get copiedToClipboard => 'Copied';

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
  String get aifaDatabaseHint => 'Italian medication database for code lookup';

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
  String get stockAndExpiryReminders => 'Stock and expiry reminders';

  @override
  String stockAndExpiryRemindersHint(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other:
          'Notify when a medication runs low or expires within $days days, and prescriptions about to expire',
      one:
          'Notify when a medication runs low or expires within 1 day, and prescriptions about to expire',
    );
    return '$_temp0';
  }

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
  String get notificationsBlocked =>
      'Notifications are blocked. Allow them for Medora in your system settings.';

  @override
  String get dataSection => 'Data';

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
  String get syncPartial => 'Completed with some errors';

  @override
  String get syncNever => 'Not synced yet';

  @override
  String lastSyncSummary(
    String time,
    int pushed,
    int pulled,
    int deleted,
    int failed,
  ) {
    return 'Last sync $time: $pushed sent, $pulled received, $deleted deleted, $failed failed';
  }

  @override
  String syncNeedsMigration(String file) {
    return 'The cloud project needs an update: apply $file';
  }

  @override
  String get syncFailedItems => 'Failed items';

  @override
  String syncSkippedBackoff(int n) {
    return '$n waiting to retry';
  }

  @override
  String get discardLocalChange => 'Discard local change';

  @override
  String get discardLocalChangeHint =>
      'Replaces your unsynced change with the server copy';

  @override
  String get ok => 'OK';

  @override
  String get advanced => 'Advanced';

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
  String wipeFailed(String error) {
    return 'Could not delete local data: $error';
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
  String get scheduleAsNeeded => 'As Needed';

  @override
  String get logDoseNow => 'Log dose';

  @override
  String get doseLogged => 'Dose logged';

  @override
  String get specificTimes => 'Specific Times';

  @override
  String get morning => 'Morning';

  @override
  String get noon => 'Noon';

  @override
  String get afternoon => 'Afternoon';

  @override
  String get evening => 'Evening';

  @override
  String get night => 'Night';

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
  String get searchSupplementByName => 'Search the supplement register';

  @override
  String get supplementSearchHint => 'Product name';

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
  String get checkYourEmailTitle => 'Check your e-mail';

  @override
  String checkYourEmailBody(String email) {
    return 'We sent a confirmation link to $email. Open it, then come back and sign in.';
  }

  @override
  String get resendConfirmation => 'Send it again';

  @override
  String get confirmationResent => 'Confirmation e-mail sent again';

  @override
  String resendCooldown(int seconds) {
    return 'You can ask for another in ${seconds}s';
  }

  @override
  String get backToSignIn => 'Back';

  @override
  String get authEmailTaken =>
      'That e-mail already has an account. Sign in instead.';

  @override
  String get authInvalidCredentials => 'Wrong e-mail or password.';

  @override
  String get authWeakPassword =>
      'That password is too weak. Use at least 6 characters.';

  @override
  String get authInvalidEmail => 'That does not look like an e-mail address.';

  @override
  String authRateLimited(int seconds) {
    return 'Too many attempts. Try again in ${seconds}s.';
  }

  @override
  String get authOffline => 'No connection. Check your network and try again.';

  @override
  String get statsDaySick => 'sick';

  @override
  String get statsDayWell => 'not sick';

  @override
  String get statistics => 'Statistics';

  @override
  String get statsSickDaysTitle => 'Days signed off';

  @override
  String statsTotalDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
      zero: 'No days',
    );
    return '$_temp0';
  }

  @override
  String statsEpisodes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count episodes',
      one: '1 episode',
    );
    return '$_temp0';
  }

  @override
  String get statsLongest => 'Longest';

  @override
  String get statsAverage => 'Average';

  @override
  String statsDaysShort(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count d',
      one: '1 d',
    );
    return '$_temp0';
  }

  @override
  String get statsByMonth => 'By month';

  @override
  String get statsByIllness => 'By illness';

  @override
  String get statsByIllnessNote =>
      'A day with two illnesses counts for both, so these can add up to more than the total.';

  @override
  String statsVsLastYear(int year) {
    return 'Compared with $year';
  }

  @override
  String statsMoreThanLastYear(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days more',
      one: '1 day more',
    );
    return '$_temp0';
  }

  @override
  String statsFewerThanLastYear(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days fewer',
      one: '1 day fewer',
    );
    return '$_temp0';
  }

  @override
  String get statsSameAsLastYear => 'The same';

  @override
  String statsNoLeaveThisYear(int year) {
    return 'No sick leave recorded in $year.';
  }

  @override
  String get statsNoLeaveEver =>
      'Record sick leave on a treatment and this fills in.';

  @override
  String statsDayDetail(String date, String illnesses) {
    return '$date: $illnesses';
  }

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
  String get signOut => 'Sign Out';

  @override
  String get alreadyHaveAccount => 'Already have an account? Sign In';

  @override
  String get dontHaveAccount => 'Don\'t have an account? Sign Up';

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
      'This replaces everything on this device with the data in Supabase. Local changes that have not been uploaded yet are lost and cannot be recovered. Continue?';

  @override
  String get forceSyncBusy =>
      'A sync is running. Try again when it has finished.';

  @override
  String get foreignDataTitle => 'Data from another account';

  @override
  String get foreignDataBody =>
      'This device holds data saved under a different account. Upload and merge it into this account, or delete it from this device?';

  @override
  String get foreignDataMerge => 'Upload and merge';

  @override
  String get foreignDataDelete => 'Delete local data';

  @override
  String get continueLabel => 'Continue';

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

  @override
  String get notificationExpiryTitle => 'Expiring soon';

  @override
  String notificationExpiryBody(String name, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$name expires in $days days',
      one: '$name expires tomorrow',
      zero: '$name expires today',
    );
    return '$_temp0';
  }

  @override
  String get notificationLowStockTitle => 'Running low';

  @override
  String notificationLowStockBody(String name, int quantity) {
    String _temp0 = intl.Intl.pluralLogic(
      quantity,
      locale: localeName,
      other: '$name: $quantity left',
      one: '$name: 1 left',
      zero: '$name: none left',
    );
    return '$_temp0';
  }

  @override
  String get useOnThisDevice => 'Use Medora on this device';

  @override
  String get useOnThisDeviceDesc =>
      'Your data stays on this device. You can turn on cloud sync later in Settings.';

  @override
  String get orSignInForCloud => 'Or sign in to sync across devices';

  @override
  String get cloudSync => 'Cloud sync';

  @override
  String cloudSyncOn(String email) {
    return 'On — signed in as $email';
  }

  @override
  String get cloudSyncOff => 'Off — data is stored only on this device';

  @override
  String get cloudSyncUnavailable => 'Not configured — tap Configure';

  @override
  String get turnOnCloudSync => 'Turn on cloud sync';

  @override
  String get turnOffCloudSync => 'Turn off cloud sync';

  @override
  String get localOnlyMode => 'Local only';

  @override
  String get unlockMedora => 'Unlock Medora';

  @override
  String get biometricNotEnrolled =>
      'No biometrics or device lock set up — add one in system settings';

  @override
  String get biometricLockedOut => 'Too many attempts — try again later';

  @override
  String get biometricNotAvailable =>
      'Biometric unlock is not available on this device';

  @override
  String get biometricFailed => 'Unlock failed';

  @override
  String get disableAppLock => 'Turn off app lock';

  @override
  String get cloudRequiredForFamily =>
      'Family sharing needs cloud sync. Turn it on in Settings.';

  @override
  String get invalidEmail => 'Enter a valid email address';

  @override
  String get passwordTooShort => 'Password must be at least 6 characters';

  @override
  String get turnOn => 'Turn on';

  @override
  String get turnOff => 'Turn off';

  @override
  String get featureUnavailableOnPlatform =>
      'This feature is not available on this device.';

  @override
  String get missedGracePeriod => 'Mark as missed after';

  @override
  String get missedGracePeriodDesc =>
      'Pending doses older than this are marked missed when the app opens';

  @override
  String minutesShort(int minutes) {
    return '$minutes min';
  }

  @override
  String hoursShort(int hours) {
    return '$hours h';
  }

  @override
  String get keepLocalData => 'Keep my data on this device';

  @override
  String get wipeLocalData => 'Delete my data from this device';

  @override
  String get turnOffCloudSyncChoice =>
      'You will be signed out. What should happen to the data stored on this device?';

  @override
  String get securitySection => 'Security';

  @override
  String get fingerprintUnlock => 'Fingerprint unlock';

  @override
  String get fingerprintUnlockDesc => 'Use biometrics to protect your data';

  @override
  String get undoTaken => 'Undo taken';

  @override
  String get continueAction => 'Continue';

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get tomorrow => 'Tomorrow';

  @override
  String get date => 'Date';

  @override
  String get clear => 'Clear';

  @override
  String get genericError => 'Something went wrong';

  @override
  String errorWithDetails(String details) {
    return 'Something went wrong: $details';
  }

  @override
  String deleteDataFailed(String details) {
    return 'Could not delete data: $details';
  }

  @override
  String get exportNotSupportedOnWeb =>
      'Export is not available in the browser yet.';

  @override
  String get exportReportTitle => 'Medora report';

  @override
  String get exportSummary => 'Home medicine cabinet summary';

  @override
  String get exportDoseRecords => 'Dose records';

  @override
  String get name => 'Name';

  @override
  String get dosage => 'Dosage';

  @override
  String get colActiveIngredient => 'Active ingredient';

  @override
  String get colMinStock => 'Min stock';

  @override
  String get colScheduled => 'Scheduled';

  @override
  String get colTaken => 'Taken';

  @override
  String get colStatus => 'Status';

  @override
  String get yesLabel => 'Yes';

  @override
  String get noLabel => 'No';

  @override
  String get onboardingCabinetTitle => 'Your cabinet';

  @override
  String get onboardingCabinetBody =>
      'Add the medicines you have at home. Medora tracks quantity and expiry for you.';

  @override
  String get onboardingTreatmentsTitle => 'Treatments';

  @override
  String get onboardingTreatmentsBody =>
      'Group medicines into a treatment with a schedule for who takes what and when.';

  @override
  String get onboardingDosesTitle => 'Daily doses';

  @override
  String get onboardingDosesBody =>
      'Each day shows what is due. Tap Take, or let reminders nudge you.';

  @override
  String get onboardingNext => 'Next';

  @override
  String get onboardingDone => 'Done';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String get checkingForUpdates => 'Checking for updates…';

  @override
  String get upToDate => 'Up to date';

  @override
  String updateAvailable(String version) {
    return 'Update available: $version';
  }

  @override
  String get updateDownload => 'Download';

  @override
  String get updateInstall => 'Install';

  @override
  String get updateLater => 'Later';

  @override
  String get updateReleaseNotes => 'What\'s new';

  @override
  String updatePublished(String date) {
    return 'Released $date';
  }

  @override
  String updateBannerTitle(String version) {
    return 'Medora $version is available';
  }

  @override
  String get updateView => 'View';

  @override
  String get updateFailed => 'Could not check for updates';

  @override
  String get updateChecksumFailed => 'The download could not be verified';

  @override
  String get updateNoAsset => 'No installer for this device';

  @override
  String get updateCancel => 'Cancel download';

  @override
  String get updateInstallExplainTitle => 'Install update';

  @override
  String get updateInstallExplainBody =>
      'Android will ask you to allow Medora to install apps, then open the installer. Your data stays on the device.';

  @override
  String get updateShowMore => 'Show more';

  @override
  String get updateShowLess => 'Show less';

  @override
  String get backupData => 'Back up data';

  @override
  String get backupDataHint =>
      'Save everything as one unencrypted JSON file — keep it somewhere private';

  @override
  String get backupAction => 'Back up';

  @override
  String backupIncludePhotos(int count, String megabytes) {
    return 'Include photos and attachments ($count files, ~$megabytes MB)';
  }

  @override
  String get backupPhotosTooLarge =>
      'That is a lot of photos — leaving them out keeps the backup small enough to share.';

  @override
  String get restoreBackup => 'Restore from backup';

  @override
  String get restoreBackupHint => 'Read a backup file back into the app';

  @override
  String get restoreAction => 'Restore';

  @override
  String get restoreReplace => 'Replace everything';

  @override
  String get restoreMerge => 'Merge with this device';

  @override
  String get restoreReplaceWarning =>
      'Everything on this device is deleted first and replaced by the backup.';

  @override
  String restoreSummary(String created, int rows, int photos) {
    return 'Created $created · $rows rows · $photos photos';
  }

  @override
  String restoreAttachmentFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count attachment files',
      one: '1 attachment file',
    );
    return '$_temp0';
  }

  @override
  String get restoreInProgress => 'Restoring…';

  @override
  String restoreDone(int rows) {
    return 'Restored $rows rows';
  }

  @override
  String get backupNotABackup => 'That file is not a Medora backup.';

  @override
  String get backupNewerVersion =>
      'This backup comes from a newer version of Medora. Update the app and try again.';

  @override
  String get backupCorrupt =>
      'This backup could not be read. Nothing was changed.';

  @override
  String get configureCloud => 'Configure cloud sync';

  @override
  String get cloudConfiguration => 'Cloud configuration';

  @override
  String get configure => 'Configure';

  @override
  String get cloudConfiguredOnDevice => 'Configured on this device';

  @override
  String get cloudConfiguredFromBuild => 'Configured by this build';

  @override
  String get cloudRestartRequired =>
      'Restart Medora to apply the new cloud settings';

  @override
  String get cloudConfigIntro =>
      'Enter your Supabase project URL and key. They are stored only on this device.';

  @override
  String get cloudProjectUrl => 'Project URL';

  @override
  String get cloudProjectUrlHint => 'https://yourproject.supabase.co';

  @override
  String get cloudAnonKey => 'Anon or publishable key';

  @override
  String get cloudKeyStored => 'Key saved on this device';

  @override
  String get cloudKeyReplace => 'Replace';

  @override
  String get paste => 'Paste';

  @override
  String get cloudTestConnection => 'Test connection';

  @override
  String get cloudTestOk => 'The project answered — these values work';

  @override
  String get cloudTestFailed => 'Could not reach the project with these values';

  @override
  String get cloudProbeBadKey => 'Reachable, but the key was rejected';

  @override
  String get cloudProbeTimeout => 'The project did not answer in time';

  @override
  String cloudProbeHttpError(int code) {
    return 'The project answered HTTP $code';
  }

  @override
  String get cloudInvalidUrl =>
      'Enter the full project URL, starting with https://';

  @override
  String get cloudKeyRequired => 'Enter the project\'s anon or publishable key';

  @override
  String get cloudConfigSaved => 'Cloud sync is ready — turn it on above';

  @override
  String get cloudConfigCleared =>
      'Cloud configuration removed from this device';

  @override
  String get rxTab => 'Prescriptions';

  @override
  String get rxNew => 'New prescription';

  @override
  String get rxEdit => 'Edit prescription';

  @override
  String get rxNoneYet => 'No prescriptions yet';

  @override
  String get rxNoneYetHint =>
      'Keep the number, validity and what is left to collect at hand';

  @override
  String get rxAdd => 'Add prescription';

  @override
  String get rxKind => 'Type';

  @override
  String get rxKindSsn => 'National health service (SSN)';

  @override
  String get rxKindWhite => 'Private (white)';

  @override
  String get rxKindWhiteRepeatable => 'Private, repeatable';

  @override
  String get rxKindReferral => 'Referral';

  @override
  String get rxKindShortSsn => 'SSN';

  @override
  String get rxKindShortWhite => 'White';

  @override
  String get rxKindShortWhiteRepeatable => 'Repeatable';

  @override
  String get rxKindShortReferral => 'Referral';

  @override
  String get rxNre => 'Prescription number (NRE)';

  @override
  String get rxNreInvalid => '15 letters or digits';

  @override
  String get rxNreDuplicate => 'This prescription number is already saved';

  @override
  String get rxNreDuplicateHint => 'Already saved';

  @override
  String get rxOpenExisting => 'Open';

  @override
  String get rxIssuedOn => 'Issued on';

  @override
  String get rxValidUntil => 'Valid until';

  @override
  String get rxExemption => 'Exemption code';

  @override
  String get rxPriority => 'Priority';

  @override
  String get rxPriorityU => 'U – within 72 hours';

  @override
  String get rxPriorityB => 'B – within 10 days';

  @override
  String get rxPriorityD => 'D – within 30 days';

  @override
  String get rxPriorityP => 'P – within 120 days';

  @override
  String get rxMaxDispensings => 'Max. pharmacy visits';

  @override
  String get rxPerson => 'Person';

  @override
  String get rxNoPerson => 'No person';

  @override
  String get rxUnknownPerson => 'Unknown person';

  @override
  String get rxItems => 'Medicines';

  @override
  String get rxAddItem => 'Add medicine';

  @override
  String get rxItemDescription => 'Medicine';

  @override
  String get rxItemPacks => 'Packs';

  @override
  String get rxNonSubstitutable => 'Not substitutable';

  @override
  String get rxStatusOpen => 'Open';

  @override
  String get rxStatusPartial => 'Partly collected';

  @override
  String get rxStatusRedeemed => 'Collected';

  @override
  String get rxStatusExpired => 'Expired';

  @override
  String get rxStatusCancelled => 'Cancelled';

  @override
  String get rxGroupDone => 'Done & expired';

  @override
  String rxDaysLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days left',
      one: '1 day left',
      zero: 'Last day',
    );
    return '$_temp0';
  }

  @override
  String rxVisitBy(String date) {
    return 'Visit by $date';
  }

  @override
  String get rxShowAtPharmacy => 'Show at pharmacy';

  @override
  String get rxTaxCode => 'Tax code';

  @override
  String get rxTaxCodeInvalid => 'Not a valid tax code';

  @override
  String get rxRedeem => 'Collect';

  @override
  String get rxRedeemTitle => 'Collect at the pharmacy';

  @override
  String get rxPharmacy => 'Pharmacy';

  @override
  String get rxAddToStock => 'Add to stock';

  @override
  String get rxUnitsToAdd => 'Units to add';

  @override
  String get rxTooManyPacks => 'More than prescribed';

  @override
  String get rxLinkMedication => 'Link to a medicine in the cabinet';

  @override
  String get rxCollectedOn => 'Collected on';

  @override
  String get rxCollections => 'Collections';

  @override
  String get rxRemoveCollection => 'Remove';

  @override
  String get rxMarkDone => 'Mark as done';

  @override
  String get rxCancelRx => 'Cancel prescription';

  @override
  String get rxDelete => 'Delete prescription';

  @override
  String get rxDeleteConfirm => 'Delete this prescription and its collections?';

  @override
  String get rxShare => 'Share number';

  @override
  String rxShareText(String nre, String taxCode) {
    return 'Prescription $nre\nTax code $taxCode';
  }

  @override
  String rxShareTextNreOnly(String nre) {
    return 'Prescription $nre';
  }

  @override
  String get rxExpiringTitle => 'Prescriptions expiring';

  @override
  String get rxNothingLeft => 'Nothing left to collect';

  @override
  String get notificationRxExpiryTitle => 'Prescription expiring';

  @override
  String notificationRxExpiryBody(String name, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$name: valid $days more days',
      one: '$name: valid until tomorrow',
      zero: '$name: last valid day',
    );
    return '$_temp0';
  }

  @override
  String get notificationAskForRx => 'Ask your doctor for a new prescription';

  @override
  String get persons => 'Persons';

  @override
  String get personsHint => 'Tax codes and exemptions for prescriptions';

  @override
  String get personNew => 'New person';

  @override
  String get personEdit => 'Edit person';

  @override
  String get personExemptions => 'Exemption codes';

  @override
  String get personExemptionsHint => 'e.g. E01, 048';

  @override
  String get personDelete => 'Delete person';

  @override
  String personDeleteConfirm(String name) {
    return 'Delete $name? Prescriptions stay.';
  }

  @override
  String get personNoneYet => 'No persons yet';

  @override
  String get rxStockNotUpdated =>
      'Collected, but the stock could not be updated';

  @override
  String get rxValidBeforeIssued => 'Valid-until is before the issue date';

  @override
  String get rxRemoveCollectionConfirm =>
      'Remove this collection? The stock is not changed.';

  @override
  String get rxSectionTitle => 'Prescription slips';

  @override
  String get rxAttachments => 'Attachments';

  @override
  String get rxAttachmentAdd => 'Add attachment';

  @override
  String get rxAttachmentCamera => 'Take photo';

  @override
  String get rxAttachmentGallery => 'Choose photo';

  @override
  String get rxAttachmentFile => 'Choose PDF or image file';

  @override
  String get rxAttachmentDelete => 'Delete attachment';

  @override
  String get rxAttachmentDeleteConfirm =>
      'Delete this attachment on all devices?';

  @override
  String get rxAttachmentTooLarge => 'The file is larger than 20 MB';

  @override
  String get rxAttachmentUnsupported =>
      'Only photos and PDF files can be attached';

  @override
  String get rxAttachmentUnreadable => 'This image could not be read';

  @override
  String get rxAttachmentNotAvailable =>
      'Not on this device yet — it arrives with the next sync';

  @override
  String get rxAttachmentPreparing => 'Preparing…';

  @override
  String rxAttachmentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count attachments',
      one: '1 attachment',
    );
    return '$_temp0';
  }
}
