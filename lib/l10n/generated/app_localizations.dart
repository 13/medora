import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_it.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('it'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Medora'**
  String get appTitle;

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navMedications.
  ///
  /// In en, this message translates to:
  /// **'Medications'**
  String get navMedications;

  /// No description provided for @navDoses.
  ///
  /// In en, this message translates to:
  /// **'Doses'**
  String get navDoses;

  /// No description provided for @navTreatments.
  ///
  /// In en, this message translates to:
  /// **'Treatments'**
  String get navTreatments;

  /// No description provided for @dashboard.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get dashboard;

  /// No description provided for @seeAll.
  ///
  /// In en, this message translates to:
  /// **'See All'**
  String get seeAll;

  /// No description provided for @todaysDoses.
  ///
  /// In en, this message translates to:
  /// **'Today\'s Doses'**
  String get todaysDoses;

  /// No description provided for @noDosesScheduled.
  ///
  /// In en, this message translates to:
  /// **'No doses scheduled for today'**
  String get noDosesScheduled;

  /// No description provided for @dosesProgress.
  ///
  /// In en, this message translates to:
  /// **'{taken} of {total} taken · {pending} pending'**
  String dosesProgress(int taken, int total, int pending);

  /// No description provided for @unableToLoadDoses.
  ///
  /// In en, this message translates to:
  /// **'Unable to load doses'**
  String get unableToLoadDoses;

  /// No description provided for @addMedication.
  ///
  /// In en, this message translates to:
  /// **'Add\nMedication'**
  String get addMedication;

  /// No description provided for @scanBarcode.
  ///
  /// In en, this message translates to:
  /// **'Scan\nBarcode'**
  String get scanBarcode;

  /// No description provided for @newTreatment.
  ///
  /// In en, this message translates to:
  /// **'New\nTreatment'**
  String get newTreatment;

  /// No description provided for @expiringSoon.
  ///
  /// In en, this message translates to:
  /// **'Expiring Soon'**
  String get expiringSoon;

  /// No description provided for @lowStock.
  ///
  /// In en, this message translates to:
  /// **'Low Stock'**
  String get lowStock;

  /// No description provided for @activeTreatments.
  ///
  /// In en, this message translates to:
  /// **'Active Treatments'**
  String get activeTreatments;

  /// No description provided for @allMedicationsWithinDate.
  ///
  /// In en, this message translates to:
  /// **'All medications are within date'**
  String get allMedicationsWithinDate;

  /// No description provided for @allMedicationsWellStocked.
  ///
  /// In en, this message translates to:
  /// **'All medications are well stocked'**
  String get allMedicationsWellStocked;

  /// No description provided for @noActiveTreatments.
  ///
  /// In en, this message translates to:
  /// **'No active treatments'**
  String get noActiveTreatments;

  /// No description provided for @expiresInDays.
  ///
  /// In en, this message translates to:
  /// **'Expires in {days} days'**
  String expiresInDays(int days);

  /// No description provided for @noExpirySet.
  ///
  /// In en, this message translates to:
  /// **'No expiry set'**
  String get noExpirySet;

  /// No description provided for @remaining.
  ///
  /// In en, this message translates to:
  /// **'{quantity} remaining'**
  String remaining(int quantity);

  /// No description provided for @startedOn.
  ///
  /// In en, this message translates to:
  /// **'Started {date}'**
  String startedOn(String date);

  /// No description provided for @medications.
  ///
  /// In en, this message translates to:
  /// **'Medications'**
  String get medications;

  /// No description provided for @searchMedications.
  ///
  /// In en, this message translates to:
  /// **'Search medications...'**
  String get searchMedications;

  /// No description provided for @noMedicationsYet.
  ///
  /// In en, this message translates to:
  /// **'No medications yet'**
  String get noMedicationsYet;

  /// No description provided for @addFirstMedication.
  ///
  /// In en, this message translates to:
  /// **'Add your first medication to get started'**
  String get addFirstMedication;

  /// No description provided for @addMedicationButton.
  ///
  /// In en, this message translates to:
  /// **'Add Medication'**
  String get addMedicationButton;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteMedication.
  ///
  /// In en, this message translates to:
  /// **'Delete Medication'**
  String get deleteMedication;

  /// No description provided for @deleteMedicationConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"?'**
  String deleteMedicationConfirm(String name);

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @noExpiry.
  ///
  /// In en, this message translates to:
  /// **'No expiry'**
  String get noExpiry;

  /// No description provided for @loadingMedications.
  ///
  /// In en, this message translates to:
  /// **'Loading medications...'**
  String get loadingMedications;

  /// No description provided for @editMedication.
  ///
  /// In en, this message translates to:
  /// **'Edit Medication'**
  String get editMedication;

  /// No description provided for @medicationNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Medication Name *'**
  String get medicationNameLabel;

  /// No description provided for @pleaseEnterMedicationName.
  ///
  /// In en, this message translates to:
  /// **'Please enter a medication name'**
  String get pleaseEnterMedicationName;

  /// No description provided for @activeIngredient.
  ///
  /// In en, this message translates to:
  /// **'Active Ingredient'**
  String get activeIngredient;

  /// No description provided for @category.
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get category;

  /// No description provided for @quantityLabel.
  ///
  /// In en, this message translates to:
  /// **'Quantity *'**
  String get quantityLabel;

  /// No description provided for @required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get required;

  /// No description provided for @invalidNumber.
  ///
  /// In en, this message translates to:
  /// **'Invalid number'**
  String get invalidNumber;

  /// No description provided for @minStock.
  ///
  /// In en, this message translates to:
  /// **'Min Stock'**
  String get minStock;

  /// No description provided for @purchaseDate.
  ///
  /// In en, this message translates to:
  /// **'Purchase Date'**
  String get purchaseDate;

  /// No description provided for @expiryDate.
  ///
  /// In en, this message translates to:
  /// **'Expiry Date'**
  String get expiryDate;

  /// No description provided for @storageLocation.
  ///
  /// In en, this message translates to:
  /// **'Storage Location'**
  String get storageLocation;

  /// No description provided for @barcode.
  ///
  /// In en, this message translates to:
  /// **'Barcode'**
  String get barcode;

  /// No description provided for @notes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get notes;

  /// No description provided for @updateMedication.
  ///
  /// In en, this message translates to:
  /// **'Update Medication'**
  String get updateMedication;

  /// No description provided for @medicationUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Medication updated successfully'**
  String get medicationUpdatedSuccessfully;

  /// No description provided for @medicationAddedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Medication added successfully'**
  String get medicationAddedSuccessfully;

  /// No description provided for @errorLoadingMedication.
  ///
  /// In en, this message translates to:
  /// **'Error loading medication: {message}'**
  String errorLoadingMedication(String message);

  /// No description provided for @selectDate.
  ///
  /// In en, this message translates to:
  /// **'Select date'**
  String get selectDate;

  /// No description provided for @medication.
  ///
  /// In en, this message translates to:
  /// **'Medication'**
  String get medication;

  /// No description provided for @medicationNotFound.
  ///
  /// In en, this message translates to:
  /// **'Medication not found'**
  String get medicationNotFound;

  /// No description provided for @quantity.
  ///
  /// In en, this message translates to:
  /// **'Quantity'**
  String get quantity;

  /// No description provided for @details.
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get details;

  /// No description provided for @minimumStock.
  ///
  /// In en, this message translates to:
  /// **'Minimum Stock'**
  String get minimumStock;

  /// No description provided for @expired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get expired;

  /// No description provided for @expiresInDaysShort.
  ///
  /// In en, this message translates to:
  /// **'Expires in {days} days'**
  String expiresInDaysShort(int days);

  /// No description provided for @valid.
  ///
  /// In en, this message translates to:
  /// **'Valid'**
  String get valid;

  /// No description provided for @quantityLeft.
  ///
  /// In en, this message translates to:
  /// **'{quantity} left'**
  String quantityLeft(int quantity);

  /// No description provided for @treatments.
  ///
  /// In en, this message translates to:
  /// **'Treatments'**
  String get treatments;

  /// No description provided for @noTreatmentsYet.
  ///
  /// In en, this message translates to:
  /// **'No treatments yet'**
  String get noTreatmentsYet;

  /// No description provided for @createTreatmentPlan.
  ///
  /// In en, this message translates to:
  /// **'Create a treatment plan for an illness'**
  String get createTreatmentPlan;

  /// No description provided for @addTreatment.
  ///
  /// In en, this message translates to:
  /// **'Add Treatment'**
  String get addTreatment;

  /// No description provided for @end.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get end;

  /// No description provided for @deleteTreatment.
  ///
  /// In en, this message translates to:
  /// **'Delete Treatment'**
  String get deleteTreatment;

  /// No description provided for @deleteTreatmentConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\" and all its prescriptions?'**
  String deleteTreatmentConfirm(String name);

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get active;

  /// No description provided for @ended.
  ///
  /// In en, this message translates to:
  /// **'Ended'**
  String get ended;

  /// No description provided for @loadingTreatments.
  ///
  /// In en, this message translates to:
  /// **'Loading treatments...'**
  String get loadingTreatments;

  /// No description provided for @newTreatmentTitle.
  ///
  /// In en, this message translates to:
  /// **'New Treatment'**
  String get newTreatmentTitle;

  /// No description provided for @treatmentNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Treatment Name *'**
  String get treatmentNameLabel;

  /// No description provided for @treatmentNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., Flu Treatment'**
  String get treatmentNameHint;

  /// No description provided for @pleaseEnterTreatmentName.
  ///
  /// In en, this message translates to:
  /// **'Please enter a treatment name'**
  String get pleaseEnterTreatmentName;

  /// No description provided for @symptoms.
  ///
  /// In en, this message translates to:
  /// **'Symptoms'**
  String get symptoms;

  /// No description provided for @symptomsHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., Fever, headache, sore throat'**
  String get symptomsHint;

  /// No description provided for @startDateLabel.
  ///
  /// In en, this message translates to:
  /// **'Start Date *'**
  String get startDateLabel;

  /// No description provided for @endDateLabel.
  ///
  /// In en, this message translates to:
  /// **'End Date (optional)'**
  String get endDateLabel;

  /// No description provided for @selectEndDate.
  ///
  /// In en, this message translates to:
  /// **'Select end date'**
  String get selectEndDate;

  /// No description provided for @createTreatment.
  ///
  /// In en, this message translates to:
  /// **'Create Treatment'**
  String get createTreatment;

  /// No description provided for @treatmentCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Treatment created successfully'**
  String get treatmentCreatedSuccessfully;

  /// No description provided for @treatment.
  ///
  /// In en, this message translates to:
  /// **'Treatment'**
  String get treatment;

  /// No description provided for @treatmentNotFound.
  ///
  /// In en, this message translates to:
  /// **'Treatment not found'**
  String get treatmentNotFound;

  /// No description provided for @endTreatment.
  ///
  /// In en, this message translates to:
  /// **'End Treatment'**
  String get endTreatment;

  /// No description provided for @endTreatmentConfirm.
  ///
  /// In en, this message translates to:
  /// **'End \"{name}\"? This will deactivate all prescriptions.'**
  String endTreatmentConfirm(String name);

  /// No description provided for @startDate.
  ///
  /// In en, this message translates to:
  /// **'Start Date'**
  String get startDate;

  /// No description provided for @endDate.
  ///
  /// In en, this message translates to:
  /// **'End Date'**
  String get endDate;

  /// No description provided for @ongoing.
  ///
  /// In en, this message translates to:
  /// **'Ongoing'**
  String get ongoing;

  /// No description provided for @prescriptions.
  ///
  /// In en, this message translates to:
  /// **'Prescriptions'**
  String get prescriptions;

  /// No description provided for @numPrescriptions.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No prescriptions} =1{1 prescription} other{{count} prescriptions}}'**
  String numPrescriptions(int count);

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @noPrescriptionsYet.
  ///
  /// In en, this message translates to:
  /// **'No prescriptions yet'**
  String get noPrescriptionsYet;

  /// No description provided for @addPrescription.
  ///
  /// In en, this message translates to:
  /// **'Add Prescription'**
  String get addPrescription;

  /// No description provided for @unknownMedication.
  ///
  /// In en, this message translates to:
  /// **'Unknown Medication'**
  String get unknownMedication;

  /// No description provided for @prescriptionSummary.
  ///
  /// In en, this message translates to:
  /// **'{dosage} · every {hours}h · {days} days'**
  String prescriptionSummary(String dosage, int hours, int days);

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @errorLoadingPrescriptions.
  ///
  /// In en, this message translates to:
  /// **'Error loading prescriptions: {message}'**
  String errorLoadingPrescriptions(String message);

  /// No description provided for @medicationLabel.
  ///
  /// In en, this message translates to:
  /// **'Medication *'**
  String get medicationLabel;

  /// No description provided for @dosageLabel.
  ///
  /// In en, this message translates to:
  /// **'Dosage *'**
  String get dosageLabel;

  /// No description provided for @dosageHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., 400mg'**
  String get dosageHint;

  /// No description provided for @intervalHoursLabel.
  ///
  /// In en, this message translates to:
  /// **'Interval (hours)'**
  String get intervalHoursLabel;

  /// No description provided for @durationDaysLabel.
  ///
  /// In en, this message translates to:
  /// **'Duration (days)'**
  String get durationDaysLabel;

  /// No description provided for @todaysDosesTitle.
  ///
  /// In en, this message translates to:
  /// **'Today\'s Doses'**
  String get todaysDosesTitle;

  /// No description provided for @noDosesScheduledToday.
  ///
  /// In en, this message translates to:
  /// **'No doses scheduled for today'**
  String get noDosesScheduledToday;

  /// No description provided for @createTreatmentForDoses.
  ///
  /// In en, this message translates to:
  /// **'Create a treatment and add prescriptions to see doses here'**
  String get createTreatmentForDoses;

  /// No description provided for @upcoming.
  ///
  /// In en, this message translates to:
  /// **'Upcoming'**
  String get upcoming;

  /// No description provided for @completed.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get completed;

  /// No description provided for @taken.
  ///
  /// In en, this message translates to:
  /// **'Taken'**
  String get taken;

  /// No description provided for @takenAt.
  ///
  /// In en, this message translates to:
  /// **'Taken at {time}'**
  String takenAt(String time);

  /// No description provided for @pending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get pending;

  /// No description provided for @skipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get skipped;

  /// No description provided for @missed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get missed;

  /// No description provided for @overdue.
  ///
  /// In en, this message translates to:
  /// **'Overdue'**
  String get overdue;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @take.
  ///
  /// In en, this message translates to:
  /// **'Take'**
  String get take;

  /// No description provided for @loadingDoses.
  ///
  /// In en, this message translates to:
  /// **'Loading doses...'**
  String get loadingDoses;

  /// No description provided for @scanBarcodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan AIC Code'**
  String get scanBarcodeTitle;

  /// No description provided for @pointCameraAtBarcode.
  ///
  /// In en, this message translates to:
  /// **'Point camera at AIC code on package'**
  String get pointCameraAtBarcode;

  /// No description provided for @enterBarcodeManually.
  ///
  /// In en, this message translates to:
  /// **'Enter code manually'**
  String get enterBarcodeManually;

  /// No description provided for @enterBarcode.
  ///
  /// In en, this message translates to:
  /// **'Enter AIC Code'**
  String get enterBarcode;

  /// No description provided for @barcodeNumber.
  ///
  /// In en, this message translates to:
  /// **'AIC code'**
  String get barcodeNumber;

  /// No description provided for @barcodeHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., A023834118'**
  String get barcodeHint;

  /// No description provided for @useBarcode.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get useBarcode;

  /// No description provided for @scanBarcodeTooltip.
  ///
  /// In en, this message translates to:
  /// **'Scan AIC Code'**
  String get scanBarcodeTooltip;

  /// No description provided for @ocrDetectedCodes.
  ///
  /// In en, this message translates to:
  /// **'Detected codes — tap to search'**
  String get ocrDetectedCodes;

  /// No description provided for @ocrScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning for AIC codes…'**
  String get ocrScanning;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @appVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get appVersion;

  /// No description provided for @colorScheme.
  ///
  /// In en, this message translates to:
  /// **'Color Scheme'**
  String get colorScheme;

  /// No description provided for @colorSchemeDesc.
  ///
  /// In en, this message translates to:
  /// **'Choose an accent color for the app'**
  String get colorSchemeDesc;

  /// No description provided for @colorTeal.
  ///
  /// In en, this message translates to:
  /// **'Teal'**
  String get colorTeal;

  /// No description provided for @colorBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get colorBlue;

  /// No description provided for @colorIndigo.
  ///
  /// In en, this message translates to:
  /// **'Indigo'**
  String get colorIndigo;

  /// No description provided for @colorPurple.
  ///
  /// In en, this message translates to:
  /// **'Purple'**
  String get colorPurple;

  /// No description provided for @colorPink.
  ///
  /// In en, this message translates to:
  /// **'Pink'**
  String get colorPink;

  /// No description provided for @colorRed.
  ///
  /// In en, this message translates to:
  /// **'Red'**
  String get colorRed;

  /// No description provided for @colorOrange.
  ///
  /// In en, this message translates to:
  /// **'Orange'**
  String get colorOrange;

  /// No description provided for @colorGreen.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get colorGreen;

  /// No description provided for @aifaDatabase.
  ///
  /// In en, this message translates to:
  /// **'AIFA Database'**
  String get aifaDatabase;

  /// No description provided for @aifaDatabaseDesc.
  ///
  /// In en, this message translates to:
  /// **'Italian medication database for code lookup'**
  String get aifaDatabaseDesc;

  /// No description provided for @aifaLastSync.
  ///
  /// In en, this message translates to:
  /// **'Last sync: {date}'**
  String aifaLastSync(String date);

  /// No description provided for @aifaNeverSynced.
  ///
  /// In en, this message translates to:
  /// **'Not yet downloaded'**
  String get aifaNeverSynced;

  /// No description provided for @aifaSyncing.
  ///
  /// In en, this message translates to:
  /// **'Downloading database…'**
  String get aifaSyncing;

  /// No description provided for @aifaSyncSuccess.
  ///
  /// In en, this message translates to:
  /// **'Database updated ({count} medications)'**
  String aifaSyncSuccess(int count);

  /// No description provided for @aifaSyncError.
  ///
  /// In en, this message translates to:
  /// **'Failed to download database'**
  String get aifaSyncError;

  /// No description provided for @syncAifaDatabase.
  ///
  /// In en, this message translates to:
  /// **'Update Database'**
  String get syncAifaDatabase;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @enableNotifications.
  ///
  /// In en, this message translates to:
  /// **'Enable Notifications'**
  String get enableNotifications;

  /// No description provided for @receiveDoseReminders.
  ///
  /// In en, this message translates to:
  /// **'Receive dose reminders'**
  String get receiveDoseReminders;

  /// No description provided for @cancelAllReminders.
  ///
  /// In en, this message translates to:
  /// **'Cancel All Reminders'**
  String get cancelAllReminders;

  /// No description provided for @removePendingNotifications.
  ///
  /// In en, this message translates to:
  /// **'Remove all pending notifications'**
  String get removePendingNotifications;

  /// No description provided for @cancelAllRemindersConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to cancel all pending reminders?'**
  String get cancelAllRemindersConfirm;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @allRemindersCancelled.
  ///
  /// In en, this message translates to:
  /// **'All reminders cancelled'**
  String get allRemindersCancelled;

  /// No description provided for @dataAndSync.
  ///
  /// In en, this message translates to:
  /// **'Data & Sync'**
  String get dataAndSync;

  /// No description provided for @online.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get online;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @connectedSyncsAutomatically.
  ///
  /// In en, this message translates to:
  /// **'Connected — data syncs automatically'**
  String get connectedSyncsAutomatically;

  /// No description provided for @usingLocalData.
  ///
  /// In en, this message translates to:
  /// **'Using local data — will sync when online'**
  String get usingLocalData;

  /// No description provided for @syncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync Now'**
  String get syncNow;

  /// No description provided for @syncIdle.
  ///
  /// In en, this message translates to:
  /// **'Tap to sync data with the cloud'**
  String get syncIdle;

  /// No description provided for @syncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing...'**
  String get syncing;

  /// No description provided for @syncSuccess.
  ///
  /// In en, this message translates to:
  /// **'Sync completed successfully'**
  String get syncSuccess;

  /// No description provided for @syncError.
  ///
  /// In en, this message translates to:
  /// **'Sync failed — tap to retry'**
  String get syncError;

  /// No description provided for @features.
  ///
  /// In en, this message translates to:
  /// **'Features'**
  String get features;

  /// No description provided for @familySharing.
  ///
  /// In en, this message translates to:
  /// **'Family Sharing'**
  String get familySharing;

  /// No description provided for @shareCabinetWithFamily.
  ///
  /// In en, this message translates to:
  /// **'Share your medicine cabinet with family'**
  String get shareCabinetWithFamily;

  /// No description provided for @exportData.
  ///
  /// In en, this message translates to:
  /// **'Export Data'**
  String get exportData;

  /// No description provided for @exportAsCsvOrPdf.
  ///
  /// In en, this message translates to:
  /// **'Export as CSV or PDF'**
  String get exportAsCsvOrPdf;

  /// No description provided for @exportDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Export Data'**
  String get exportDataTitle;

  /// No description provided for @exportYourData.
  ///
  /// In en, this message translates to:
  /// **'Export Your Data'**
  String get exportYourData;

  /// No description provided for @chooseWhatToExport.
  ///
  /// In en, this message translates to:
  /// **'Choose what to export and the format'**
  String get chooseWhatToExport;

  /// No description provided for @include.
  ///
  /// In en, this message translates to:
  /// **'Include'**
  String get include;

  /// No description provided for @fullMedicationInventory.
  ///
  /// In en, this message translates to:
  /// **'Full medication inventory'**
  String get fullMedicationInventory;

  /// No description provided for @treatmentPlansAndHistory.
  ///
  /// In en, this message translates to:
  /// **'Treatment plans and history'**
  String get treatmentPlansAndHistory;

  /// No description provided for @doseLogs.
  ///
  /// In en, this message translates to:
  /// **'Dose Logs'**
  String get doseLogs;

  /// No description provided for @medicationIntakeRecords.
  ///
  /// In en, this message translates to:
  /// **'Medication intake records'**
  String get medicationIntakeRecords;

  /// No description provided for @doseLogDateRange.
  ///
  /// In en, this message translates to:
  /// **'Dose Log Date Range'**
  String get doseLogDateRange;

  /// No description provided for @from.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get from;

  /// No description provided for @to.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get to;

  /// No description provided for @format.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get format;

  /// No description provided for @exporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting...'**
  String get exporting;

  /// No description provided for @exportAndShare.
  ///
  /// In en, this message translates to:
  /// **'Export & Share'**
  String get exportAndShare;

  /// No description provided for @noDataToExport.
  ///
  /// In en, this message translates to:
  /// **'No data to export'**
  String get noDataToExport;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @familySharingTitle.
  ///
  /// In en, this message translates to:
  /// **'Family Sharing'**
  String get familySharingTitle;

  /// No description provided for @loadingFamily.
  ///
  /// In en, this message translates to:
  /// **'Loading family...'**
  String get loadingFamily;

  /// No description provided for @noFamilyGroup.
  ///
  /// In en, this message translates to:
  /// **'No Family Group'**
  String get noFamilyGroup;

  /// No description provided for @noFamilyDescription.
  ///
  /// In en, this message translates to:
  /// **'Create a family group to share your medicine cabinet, or join an existing one with an invite code.'**
  String get noFamilyDescription;

  /// No description provided for @createFamily.
  ///
  /// In en, this message translates to:
  /// **'Create Family'**
  String get createFamily;

  /// No description provided for @joinWithCode.
  ///
  /// In en, this message translates to:
  /// **'Join with Code'**
  String get joinWithCode;

  /// No description provided for @familyName.
  ///
  /// In en, this message translates to:
  /// **'Family Name'**
  String get familyName;

  /// No description provided for @familyNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., Smith Family'**
  String get familyNameHint;

  /// No description provided for @yourName.
  ///
  /// In en, this message translates to:
  /// **'Your Name'**
  String get yourName;

  /// No description provided for @yourNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., John'**
  String get yourNameHint;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @joinFamily.
  ///
  /// In en, this message translates to:
  /// **'Join Family'**
  String get joinFamily;

  /// No description provided for @inviteCode.
  ///
  /// In en, this message translates to:
  /// **'Invite Code'**
  String get inviteCode;

  /// No description provided for @inviteCodeHint.
  ///
  /// In en, this message translates to:
  /// **'e.g., ABC123'**
  String get inviteCodeHint;

  /// No description provided for @join.
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get join;

  /// No description provided for @copyCode.
  ///
  /// In en, this message translates to:
  /// **'Copy code'**
  String get copyCode;

  /// No description provided for @codeCopied.
  ///
  /// In en, this message translates to:
  /// **'Code copied to clipboard'**
  String get codeCopied;

  /// No description provided for @shareCode.
  ///
  /// In en, this message translates to:
  /// **'Share code'**
  String get shareCode;

  /// No description provided for @joinMedoraFamily.
  ///
  /// In en, this message translates to:
  /// **'Join my Medora family! Use code: {code}'**
  String joinMedoraFamily(String code);

  /// No description provided for @generateNewCode.
  ///
  /// In en, this message translates to:
  /// **'Generate New Code'**
  String get generateNewCode;

  /// No description provided for @members.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get members;

  /// No description provided for @noMembersYet.
  ///
  /// In en, this message translates to:
  /// **'No members yet'**
  String get noMembersYet;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @owner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get owner;

  /// No description provided for @member.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get member;

  /// No description provided for @removeMember.
  ///
  /// In en, this message translates to:
  /// **'Remove Member'**
  String get removeMember;

  /// No description provided for @removeMemberConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from the family?'**
  String removeMemberConfirm(String name);

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @leaveFamily.
  ///
  /// In en, this message translates to:
  /// **'Leave Family'**
  String get leaveFamily;

  /// No description provided for @leaveFamilyConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to leave this family? You will no longer have access to shared medications.'**
  String get leaveFamilyConfirm;

  /// No description provided for @leave.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leave;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String error(String message);

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @darkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get darkMode;

  /// No description provided for @darkModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get darkModeLabel;

  /// No description provided for @lightMode.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get lightMode;

  /// No description provided for @systemDefault.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get systemDefault;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @lookingUpBarcode.
  ///
  /// In en, this message translates to:
  /// **'Looking up barcode…'**
  String get lookingUpBarcode;

  /// No description provided for @autoFilledFromBarcode.
  ///
  /// In en, this message translates to:
  /// **'Product found — fields auto-filled'**
  String get autoFilledFromBarcode;

  /// No description provided for @barcodeNotFound.
  ///
  /// In en, this message translates to:
  /// **'Product not found — enter details manually'**
  String get barcodeNotFound;

  /// No description provided for @editTreatment.
  ///
  /// In en, this message translates to:
  /// **'Edit Treatment'**
  String get editTreatment;

  /// No description provided for @treatmentUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Treatment updated successfully'**
  String get treatmentUpdatedSuccessfully;

  /// No description provided for @updateTreatment.
  ///
  /// In en, this message translates to:
  /// **'Update Treatment'**
  String get updateTreatment;

  /// No description provided for @editPrescription.
  ///
  /// In en, this message translates to:
  /// **'Edit Prescription'**
  String get editPrescription;

  /// No description provided for @prescriptionUpdated.
  ///
  /// In en, this message translates to:
  /// **'Prescription updated'**
  String get prescriptionUpdated;

  /// No description provided for @scheduleType.
  ///
  /// In en, this message translates to:
  /// **'Schedule Type'**
  String get scheduleType;

  /// No description provided for @fixedInterval.
  ///
  /// In en, this message translates to:
  /// **'Fixed Interval'**
  String get fixedInterval;

  /// No description provided for @timesPerDay.
  ///
  /// In en, this message translates to:
  /// **'Times per Day'**
  String get timesPerDay;

  /// No description provided for @specificTimes.
  ///
  /// In en, this message translates to:
  /// **'Specific Times'**
  String get specificTimes;

  /// No description provided for @morning.
  ///
  /// In en, this message translates to:
  /// **'Morning'**
  String get morning;

  /// No description provided for @noon.
  ///
  /// In en, this message translates to:
  /// **'Noon'**
  String get noon;

  /// No description provided for @evening.
  ///
  /// In en, this message translates to:
  /// **'Evening'**
  String get evening;

  /// No description provided for @beforeSleep.
  ///
  /// In en, this message translates to:
  /// **'Before Sleep'**
  String get beforeSleep;

  /// No description provided for @selectTimes.
  ///
  /// In en, this message translates to:
  /// **'Select Times'**
  String get selectTimes;

  /// No description provided for @everyXHours.
  ///
  /// In en, this message translates to:
  /// **'Every {hours} hours'**
  String everyXHours(int hours);

  /// No description provided for @xTimesDaily.
  ///
  /// In en, this message translates to:
  /// **'{count} times daily'**
  String xTimesDaily(int count);

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @selectMedication.
  ///
  /// In en, this message translates to:
  /// **'Select Medication'**
  String get selectMedication;

  /// No description provided for @results.
  ///
  /// In en, this message translates to:
  /// **'results'**
  String get results;

  /// No description provided for @searchByBarcode.
  ///
  /// In en, this message translates to:
  /// **'Search by code'**
  String get searchByBarcode;

  /// No description provided for @archiveTreatment.
  ///
  /// In en, this message translates to:
  /// **'Archive Treatment'**
  String get archiveTreatment;

  /// No description provided for @archiveTreatmentConfirm.
  ///
  /// In en, this message translates to:
  /// **'Archive \"{name}\"? It will be moved to the archive and can be viewed later.'**
  String archiveTreatmentConfirm(String name);

  /// No description provided for @archive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get archive;

  /// No description provided for @archived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get archived;

  /// No description provided for @deletePrescription.
  ///
  /// In en, this message translates to:
  /// **'Delete Prescription'**
  String get deletePrescription;

  /// No description provided for @deletePrescriptionConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this prescription? This action cannot be undone.'**
  String get deletePrescriptionConfirm;

  /// No description provided for @prescriptionDeleted.
  ///
  /// In en, this message translates to:
  /// **'Prescription deleted'**
  String get prescriptionDeleted;

  /// No description provided for @patientName.
  ///
  /// In en, this message translates to:
  /// **'Patient'**
  String get patientName;

  /// No description provided for @patientNameHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. Baby, Mom...'**
  String get patientNameHint;

  /// No description provided for @doseHistory.
  ///
  /// In en, this message translates to:
  /// **'Dose History'**
  String get doseHistory;

  /// No description provided for @noDoseHistory.
  ///
  /// In en, this message translates to:
  /// **'No dose history yet'**
  String get noDoseHistory;

  /// No description provided for @medicationPhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get medicationPhoto;

  /// No description provided for @addPhoto.
  ///
  /// In en, this message translates to:
  /// **'Add Photo'**
  String get addPhoto;

  /// No description provided for @changePhoto.
  ///
  /// In en, this message translates to:
  /// **'Change Photo'**
  String get changePhoto;

  /// No description provided for @photoSource.
  ///
  /// In en, this message translates to:
  /// **'Photo Source'**
  String get photoSource;

  /// No description provided for @camera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// No description provided for @gallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get gallery;

  /// No description provided for @forPatient.
  ///
  /// In en, this message translates to:
  /// **'For: {name}'**
  String forPatient(String name);

  /// No description provided for @catPainkiller.
  ///
  /// In en, this message translates to:
  /// **'Painkiller'**
  String get catPainkiller;

  /// No description provided for @catAntibiotic.
  ///
  /// In en, this message translates to:
  /// **'Antibiotic'**
  String get catAntibiotic;

  /// No description provided for @catAntihistamine.
  ///
  /// In en, this message translates to:
  /// **'Antihistamine'**
  String get catAntihistamine;

  /// No description provided for @catVitamin.
  ///
  /// In en, this message translates to:
  /// **'Vitamin'**
  String get catVitamin;

  /// No description provided for @catSupplement.
  ///
  /// In en, this message translates to:
  /// **'Supplement'**
  String get catSupplement;

  /// No description provided for @catColdFlu.
  ///
  /// In en, this message translates to:
  /// **'Cold & Flu'**
  String get catColdFlu;

  /// No description provided for @catDigestive.
  ///
  /// In en, this message translates to:
  /// **'Digestive'**
  String get catDigestive;

  /// No description provided for @catSkinCare.
  ///
  /// In en, this message translates to:
  /// **'Skin Care'**
  String get catSkinCare;

  /// No description provided for @catEyeCare.
  ///
  /// In en, this message translates to:
  /// **'Eye Care'**
  String get catEyeCare;

  /// No description provided for @catFirstAid.
  ///
  /// In en, this message translates to:
  /// **'First Aid'**
  String get catFirstAid;

  /// No description provided for @catOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get catOther;

  /// No description provided for @activeIngredients.
  ///
  /// In en, this message translates to:
  /// **'Active Ingredients'**
  String get activeIngredients;

  /// No description provided for @symptomsField.
  ///
  /// In en, this message translates to:
  /// **'Symptoms / Used For'**
  String get symptomsField;

  /// No description provided for @patientTagsField.
  ///
  /// In en, this message translates to:
  /// **'Patient'**
  String get patientTagsField;

  /// No description provided for @addTag.
  ///
  /// In en, this message translates to:
  /// **'Add tag...'**
  String get addTag;

  /// No description provided for @treatsSymptoms.
  ///
  /// In en, this message translates to:
  /// **'Treats'**
  String get treatsSymptoms;

  /// No description provided for @uncategorized.
  ///
  /// In en, this message translates to:
  /// **'Uncategorized'**
  String get uncategorized;

  /// No description provided for @deactivatePrescription.
  ///
  /// In en, this message translates to:
  /// **'Deactivate'**
  String get deactivatePrescription;

  /// No description provided for @prescriptionDeactivated.
  ///
  /// In en, this message translates to:
  /// **'Prescription deactivated'**
  String get prescriptionDeactivated;

  /// No description provided for @reactivatePrescription.
  ///
  /// In en, this message translates to:
  /// **'Reactivate'**
  String get reactivatePrescription;

  /// No description provided for @prescriptionReactivated.
  ///
  /// In en, this message translates to:
  /// **'Prescription reactivated'**
  String get prescriptionReactivated;

  /// No description provided for @locMedicineCabinet.
  ///
  /// In en, this message translates to:
  /// **'Medicine Cabinet'**
  String get locMedicineCabinet;

  /// No description provided for @locBathroom.
  ///
  /// In en, this message translates to:
  /// **'Bathroom'**
  String get locBathroom;

  /// No description provided for @locKitchen.
  ///
  /// In en, this message translates to:
  /// **'Kitchen'**
  String get locKitchen;

  /// No description provided for @locBedroom.
  ///
  /// In en, this message translates to:
  /// **'Bedroom'**
  String get locBedroom;

  /// No description provided for @locRefrigerator.
  ///
  /// In en, this message translates to:
  /// **'Refrigerator'**
  String get locRefrigerator;

  /// No description provided for @locFirstAidKit.
  ///
  /// In en, this message translates to:
  /// **'First Aid Kit'**
  String get locFirstAidKit;

  /// No description provided for @locOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get locOther;

  /// No description provided for @deleteAllData.
  ///
  /// In en, this message translates to:
  /// **'Delete All Data'**
  String get deleteAllData;

  /// No description provided for @deleteAllDataDesc.
  ///
  /// In en, this message translates to:
  /// **'Remove all medications, treatments, doses and prescriptions'**
  String get deleteAllDataDesc;

  /// No description provided for @deleteAllDataConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete ALL your data locally and online. Type DELETE to confirm.'**
  String get deleteAllDataConfirm;

  /// No description provided for @typeDeleteToConfirm.
  ///
  /// In en, this message translates to:
  /// **'Type DELETE to confirm'**
  String get typeDeleteToConfirm;

  /// No description provided for @allDataDeleted.
  ///
  /// In en, this message translates to:
  /// **'All data has been deleted'**
  String get allDataDeleted;

  /// No description provided for @dangerZone.
  ///
  /// In en, this message translates to:
  /// **'Danger Zone'**
  String get dangerZone;

  /// No description provided for @treatmentPatientTags.
  ///
  /// In en, this message translates to:
  /// **'Patient'**
  String get treatmentPatientTags;

  /// No description provided for @treatmentSymptomTags.
  ///
  /// In en, this message translates to:
  /// **'Symptoms'**
  String get treatmentSymptomTags;

  /// No description provided for @searchTreatments.
  ///
  /// In en, this message translates to:
  /// **'Search treatments…'**
  String get searchTreatments;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results found'**
  String get noResults;

  /// No description provided for @medicationDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get medicationDescription;

  /// No description provided for @manufacturerLabel.
  ///
  /// In en, this message translates to:
  /// **'Manufacturer'**
  String get manufacturerLabel;

  /// No description provided for @formLabel.
  ///
  /// In en, this message translates to:
  /// **'Form'**
  String get formLabel;

  /// No description provided for @atcCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'ATC Code'**
  String get atcCodeLabel;

  /// No description provided for @searchAifaByName.
  ///
  /// In en, this message translates to:
  /// **'Search AIFA Database'**
  String get searchAifaByName;

  /// No description provided for @quantityUnit.
  ///
  /// In en, this message translates to:
  /// **'Unit'**
  String get quantityUnit;

  /// No description provided for @unitPieces.
  ///
  /// In en, this message translates to:
  /// **'Pieces'**
  String get unitPieces;

  /// No description provided for @unitPills.
  ///
  /// In en, this message translates to:
  /// **'Pills'**
  String get unitPills;

  /// No description provided for @unitTablets.
  ///
  /// In en, this message translates to:
  /// **'Tablets'**
  String get unitTablets;

  /// No description provided for @unitCapsules.
  ///
  /// In en, this message translates to:
  /// **'Capsules'**
  String get unitCapsules;

  /// No description provided for @unitMl.
  ///
  /// In en, this message translates to:
  /// **'ml'**
  String get unitMl;

  /// No description provided for @unitDrops.
  ///
  /// In en, this message translates to:
  /// **'Drops'**
  String get unitDrops;

  /// No description provided for @unitBustine.
  ///
  /// In en, this message translates to:
  /// **'Sachets'**
  String get unitBustine;

  /// No description provided for @unitAmpoules.
  ///
  /// In en, this message translates to:
  /// **'Ampoules'**
  String get unitAmpoules;

  /// No description provided for @unitSuppositories.
  ///
  /// In en, this message translates to:
  /// **'Suppositories'**
  String get unitSuppositories;

  /// No description provided for @unitPatches.
  ///
  /// In en, this message translates to:
  /// **'Patches'**
  String get unitPatches;

  /// No description provided for @autoDiminish.
  ///
  /// In en, this message translates to:
  /// **'Auto-decrease stock'**
  String get autoDiminish;

  /// No description provided for @autoDiminishHint.
  ///
  /// In en, this message translates to:
  /// **'Automatically reduce medication quantity when a dose is taken'**
  String get autoDiminishHint;

  /// No description provided for @unarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get unarchive;

  /// No description provided for @archivedMedications.
  ///
  /// In en, this message translates to:
  /// **'Archived Medications'**
  String get archivedMedications;

  /// No description provided for @showArchived.
  ///
  /// In en, this message translates to:
  /// **'Show archived'**
  String get showArchived;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get signIn;

  /// No description provided for @signUp.
  ///
  /// In en, this message translates to:
  /// **'Sign Up'**
  String get signUp;

  /// No description provided for @createAccount.
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get createAccount;

  /// No description provided for @email.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @continueAsGuest.
  ///
  /// In en, this message translates to:
  /// **'Continue as Guest'**
  String get continueAsGuest;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get signOut;

  /// No description provided for @alreadyHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Sign In'**
  String get alreadyHaveAccount;

  /// No description provided for @dontHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account? Sign Up'**
  String get dontHaveAccount;

  /// No description provided for @useOfflineMode.
  ///
  /// In en, this message translates to:
  /// **'Use Offline Mode'**
  String get useOfflineMode;

  /// No description provided for @forcePush.
  ///
  /// In en, this message translates to:
  /// **'Force Push'**
  String get forcePush;

  /// No description provided for @forcePull.
  ///
  /// In en, this message translates to:
  /// **'Force Pull'**
  String get forcePull;

  /// No description provided for @forcePushTitle.
  ///
  /// In en, this message translates to:
  /// **'Force Push to Cloud'**
  String get forcePushTitle;

  /// No description provided for @forcePullTitle.
  ///
  /// In en, this message translates to:
  /// **'Force Pull from Cloud'**
  String get forcePullTitle;

  /// No description provided for @forcePushConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will overwrite all data in Supabase with your local data. This action cannot be undone. Continue?'**
  String get forcePushConfirm;

  /// No description provided for @forcePullConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will overwrite all your local data with data from Supabase. Any unsynced local changes will be lost. Continue?'**
  String get forcePullConfirm;

  /// No description provided for @continueLabel.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueLabel;

  /// No description provided for @daysLabel.
  ///
  /// In en, this message translates to:
  /// **'Days'**
  String get daysLabel;

  /// No description provided for @leftLabel.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get leftLabel;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en', 'it'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'it':
      return AppLocalizationsIt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
