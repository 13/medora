// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'Medora';

  @override
  String get navHome => 'Startseite';

  @override
  String get navMedications => 'Medikamente';

  @override
  String get navDoses => 'Dosen';

  @override
  String get navTreatments => 'Behandlungen';

  @override
  String get dashboard => 'Übersicht';

  @override
  String get seeAll => 'Alle anzeigen';

  @override
  String get todaysDoses => 'Heutige Dosen';

  @override
  String get noDosesScheduled => 'Keine Dosen für heute geplant';

  @override
  String dosesProgress(int taken, int total, int pending) {
    return '$taken von $total eingenommen · $pending ausstehend';
  }

  @override
  String get unableToLoadDoses => 'Dosen konnten nicht geladen werden';

  @override
  String get addMedication => 'Medikament\nhinzufügen';

  @override
  String get scanBarcode => 'Barcode\nscannen';

  @override
  String get newTreatment => 'Neue\nBehandlung';

  @override
  String get expiringSoon => 'Bald ablaufend';

  @override
  String get lowStock => 'Niedriger Bestand';

  @override
  String get activeTreatments => 'Aktive Behandlungen';

  @override
  String get allMedicationsWithinDate => 'Alle Medikamente sind haltbar';

  @override
  String get allMedicationsWellStocked => 'Alle Medikamente sind vorrätig';

  @override
  String get noActiveTreatments => 'Keine aktiven Behandlungen';

  @override
  String expiresInDays(int days) {
    return 'Läuft in $days Tagen ab';
  }

  @override
  String get noExpirySet => 'Kein Ablaufdatum gesetzt';

  @override
  String remaining(int quantity) {
    return '$quantity übrig';
  }

  @override
  String startedOn(String date) {
    return 'Gestartet $date';
  }

  @override
  String get medications => 'Medikamente';

  @override
  String get searchMedications => 'Medikamente suchen...';

  @override
  String get noMedicationsYet => 'Noch keine Medikamente';

  @override
  String get addFirstMedication => 'Fügen Sie Ihr erstes Medikament hinzu';

  @override
  String get addMedicationButton => 'Medikament hinzufügen';

  @override
  String get edit => 'Bearbeiten';

  @override
  String get delete => 'Löschen';

  @override
  String get deleteMedication => 'Medikament löschen';

  @override
  String deleteMedicationConfirm(String name) {
    return 'Möchten Sie \"$name\" wirklich löschen?';
  }

  @override
  String get cancel => 'Abbrechen';

  @override
  String get noExpiry => 'Kein Ablaufdatum';

  @override
  String get loadingMedications => 'Medikamente werden geladen...';

  @override
  String get editMedication => 'Medikament bearbeiten';

  @override
  String get medicationNameLabel => 'Medikamentenname *';

  @override
  String get pleaseEnterMedicationName =>
      'Bitte geben Sie einen Medikamentennamen ein';

  @override
  String get activeIngredient => 'Wirkstoff';

  @override
  String get category => 'Kategorie';

  @override
  String get quantityLabel => 'Menge *';

  @override
  String get required => 'Erforderlich';

  @override
  String get invalidNumber => 'Ungültige Zahl';

  @override
  String get minStock => 'Mindestbestand';

  @override
  String get purchaseDate => 'Kaufdatum';

  @override
  String get expiryDate => 'Ablaufdatum';

  @override
  String get storageLocation => 'Aufbewahrungsort';

  @override
  String get barcode => 'Barcode';

  @override
  String get notes => 'Notizen';

  @override
  String get updateMedication => 'Medikament aktualisieren';

  @override
  String get medicationUpdatedSuccessfully =>
      'Medikament erfolgreich aktualisiert';

  @override
  String get medicationAddedSuccessfully =>
      'Medikament erfolgreich hinzugefügt';

  @override
  String errorLoadingMedication(String message) {
    return 'Fehler beim Laden des Medikaments: $message';
  }

  @override
  String get selectDate => 'Datum auswählen';

  @override
  String get medication => 'Medikament';

  @override
  String get medicationNotFound => 'Medikament nicht gefunden';

  @override
  String get quantity => 'Menge';

  @override
  String get details => 'Details';

  @override
  String get minimumStock => 'Mindestbestand';

  @override
  String get expired => 'Abgelaufen';

  @override
  String expiresInDaysShort(int days) {
    return 'Läuft in $days Tagen ab';
  }

  @override
  String get valid => 'Gültig';

  @override
  String quantityLeft(int quantity) {
    return '$quantity übrig';
  }

  @override
  String get treatments => 'Behandlungen';

  @override
  String get noTreatmentsYet => 'Noch keine Behandlungen';

  @override
  String get createTreatmentPlan =>
      'Erstellen Sie einen Behandlungsplan für eine Erkrankung';

  @override
  String get addTreatment => 'Behandlung hinzufügen';

  @override
  String get end => 'Beenden';

  @override
  String get deleteTreatment => 'Behandlung löschen';

  @override
  String deleteTreatmentConfirm(String name) {
    return '\"$name\" und alle Verschreibungen löschen?';
  }

  @override
  String get active => 'Aktiv';

  @override
  String get ended => 'Beendet';

  @override
  String get loadingTreatments => 'Behandlungen werden geladen...';

  @override
  String get newTreatmentTitle => 'Neue Behandlung';

  @override
  String get treatmentNameLabel => 'Behandlungsname *';

  @override
  String get treatmentNameHint => 'z.B. Grippebehandlung';

  @override
  String get pleaseEnterTreatmentName =>
      'Bitte geben Sie einen Behandlungsnamen ein';

  @override
  String get symptoms => 'Symptome';

  @override
  String get symptomsHint => 'z.B. Fieber, Kopfschmerzen, Halsschmerzen';

  @override
  String get startDateLabel => 'Startdatum *';

  @override
  String get endDateLabel => 'Enddatum (optional)';

  @override
  String get selectEndDate => 'Enddatum auswählen';

  @override
  String get createTreatment => 'Behandlung erstellen';

  @override
  String get treatmentCreatedSuccessfully => 'Behandlung erfolgreich erstellt';

  @override
  String get treatment => 'Behandlung';

  @override
  String get treatmentNotFound => 'Behandlung nicht gefunden';

  @override
  String get endTreatment => 'Behandlung beenden';

  @override
  String endTreatmentConfirm(String name) {
    return '\"$name\" beenden? Alle Verschreibungen werden deaktiviert.';
  }

  @override
  String get startDate => 'Startdatum';

  @override
  String get endDate => 'Enddatum';

  @override
  String get ongoing => 'Laufend';

  @override
  String get prescriptions => 'Verschreibungen';

  @override
  String get add => 'Hinzufügen';

  @override
  String get noPrescriptionsYet => 'Noch keine Verschreibungen';

  @override
  String get addPrescription => 'Verschreibung hinzufügen';

  @override
  String get unknownMedication => 'Unbekanntes Medikament';

  @override
  String prescriptionSummary(String dosage, int hours, int days) {
    return '$dosage · alle ${hours}h · $days Tage';
  }

  @override
  String get done => 'Fertig';

  @override
  String errorLoadingPrescriptions(String message) {
    return 'Fehler beim Laden der Verschreibungen: $message';
  }

  @override
  String get medicationLabel => 'Medikament *';

  @override
  String get dosageLabel => 'Dosierung *';

  @override
  String get dosageHint => 'z.B. 400mg';

  @override
  String get intervalHoursLabel => 'Intervall (Stunden)';

  @override
  String get durationDaysLabel => 'Dauer (Tage)';

  @override
  String get todaysDosesTitle => 'Heutige Dosen';

  @override
  String get noDosesScheduledToday => 'Keine Dosen für heute geplant';

  @override
  String get createTreatmentForDoses =>
      'Erstellen Sie eine Behandlung und fügen Sie Verschreibungen hinzu, um Dosen hier zu sehen';

  @override
  String get upcoming => 'Bevorstehend';

  @override
  String get completed => 'Abgeschlossen';

  @override
  String get taken => 'Eingenommen';

  @override
  String get pending => 'Ausstehend';

  @override
  String get skipped => 'Übersprungen';

  @override
  String get missed => 'Verpasst';

  @override
  String get overdue => 'Überfällig';

  @override
  String get skip => 'Überspringen';

  @override
  String get take => 'Einnehmen';

  @override
  String get loadingDoses => 'Dosen werden geladen...';

  @override
  String get scanBarcodeTitle => 'AIC-Code scannen';

  @override
  String get pointCameraAtBarcode =>
      'Kamera auf den AIC-Code der Packung richten';

  @override
  String get enterBarcodeManually => 'Code manuell eingeben';

  @override
  String get enterBarcode => 'AIC-Code eingeben';

  @override
  String get barcodeNumber => 'AIC-Code';

  @override
  String get barcodeHint => 'z.B. A023834118';

  @override
  String get useBarcode => 'Suchen';

  @override
  String get scanBarcodeTooltip => 'AIC-Code scannen';

  @override
  String get ocrDetectedCodes => 'Erkannte Codes — zum Suchen tippen';

  @override
  String get ocrScanning => 'AIC-Codes werden gesucht…';

  @override
  String get settings => 'Einstellungen';

  @override
  String get about => 'Über';

  @override
  String get appVersion => 'App-Version';

  @override
  String get colorScheme => 'Farbschema';

  @override
  String get colorSchemeDesc => 'Wählen Sie eine Akzentfarbe für die App';

  @override
  String get colorTeal => 'Türkis';

  @override
  String get colorBlue => 'Blau';

  @override
  String get colorIndigo => 'Indigo';

  @override
  String get colorPurple => 'Lila';

  @override
  String get colorPink => 'Pink';

  @override
  String get colorRed => 'Rot';

  @override
  String get colorOrange => 'Orange';

  @override
  String get colorGreen => 'Grün';

  @override
  String get aifaDatabase => 'AIFA-Datenbank';

  @override
  String get aifaDatabaseDesc =>
      'Italienische Medikamentendatenbank für Code-Suche';

  @override
  String aifaLastSync(String date) {
    return 'Letzte Aktualisierung: $date';
  }

  @override
  String get aifaNeverSynced => 'Noch nicht heruntergeladen';

  @override
  String get aifaSyncing => 'Datenbank wird heruntergeladen…';

  @override
  String aifaSyncSuccess(int count) {
    return 'Datenbank aktualisiert ($count Medikamente)';
  }

  @override
  String get aifaSyncError => 'Datenbank-Download fehlgeschlagen';

  @override
  String get syncAifaDatabase => 'Datenbank aktualisieren';

  @override
  String get notifications => 'Benachrichtigungen';

  @override
  String get enableNotifications => 'Benachrichtigungen aktivieren';

  @override
  String get receiveDoseReminders => 'Erinnerungen an Einnahmen erhalten';

  @override
  String get cancelAllReminders => 'Alle Erinnerungen abbrechen';

  @override
  String get removePendingNotifications =>
      'Alle ausstehenden Benachrichtigungen entfernen';

  @override
  String get cancelAllRemindersConfirm =>
      'Möchten Sie wirklich alle ausstehenden Erinnerungen abbrechen?';

  @override
  String get no => 'Nein';

  @override
  String get yes => 'Ja';

  @override
  String get allRemindersCancelled => 'Alle Erinnerungen abgebrochen';

  @override
  String get dataAndSync => 'Daten & Synchronisierung';

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get connectedSyncsAutomatically =>
      'Verbunden — Daten werden automatisch synchronisiert';

  @override
  String get usingLocalData =>
      'Lokale Daten — wird synchronisiert, wenn online';

  @override
  String get syncNow => 'Jetzt synchronisieren';

  @override
  String get syncIdle => 'Tippen, um Daten mit der Cloud zu synchronisieren';

  @override
  String get syncing => 'Synchronisiere...';

  @override
  String get syncSuccess => 'Synchronisierung erfolgreich abgeschlossen';

  @override
  String get syncError =>
      'Synchronisierung fehlgeschlagen — tippen zum Wiederholen';

  @override
  String get features => 'Funktionen';

  @override
  String get familySharing => 'Familienfreigabe';

  @override
  String get shareCabinetWithFamily =>
      'Teilen Sie Ihre Hausapotheke mit der Familie';

  @override
  String get exportData => 'Daten exportieren';

  @override
  String get exportAsCsvOrPdf => 'Als CSV oder PDF exportieren';

  @override
  String get exportDataTitle => 'Daten exportieren';

  @override
  String get exportYourData => 'Ihre Daten exportieren';

  @override
  String get chooseWhatToExport => 'Wählen Sie, was exportiert werden soll';

  @override
  String get include => 'Einschließen';

  @override
  String get fullMedicationInventory => 'Vollständiges Medikamenteninventar';

  @override
  String get treatmentPlansAndHistory => 'Behandlungspläne und Verlauf';

  @override
  String get doseLogs => 'Dosisprotokolle';

  @override
  String get medicationIntakeRecords => 'Einnahmeprotokolle';

  @override
  String get doseLogDateRange => 'Dosisprotokoll-Zeitraum';

  @override
  String get from => 'Von';

  @override
  String get to => 'Bis';

  @override
  String get format => 'Format';

  @override
  String get exporting => 'Exportiere...';

  @override
  String get exportAndShare => 'Exportieren & Teilen';

  @override
  String get noDataToExport => 'Keine Daten zum Exportieren';

  @override
  String exportFailed(String error) {
    return 'Export fehlgeschlagen: $error';
  }

  @override
  String get familySharingTitle => 'Familienfreigabe';

  @override
  String get loadingFamily => 'Familie wird geladen...';

  @override
  String get noFamilyGroup => 'Keine Familiengruppe';

  @override
  String get noFamilyDescription =>
      'Erstellen Sie eine Familiengruppe, um Ihre Hausapotheke zu teilen, oder treten Sie einer bestehenden mit einem Einladungscode bei.';

  @override
  String get createFamily => 'Familie erstellen';

  @override
  String get joinWithCode => 'Mit Code beitreten';

  @override
  String get familyName => 'Familienname';

  @override
  String get familyNameHint => 'z.B. Familie Müller';

  @override
  String get yourName => 'Ihr Name';

  @override
  String get yourNameHint => 'z.B. Hans';

  @override
  String get create => 'Erstellen';

  @override
  String get joinFamily => 'Familie beitreten';

  @override
  String get inviteCode => 'Einladungscode';

  @override
  String get inviteCodeHint => 'z.B. ABC123';

  @override
  String get join => 'Beitreten';

  @override
  String get copyCode => 'Code kopieren';

  @override
  String get codeCopied => 'Code in Zwischenablage kopiert';

  @override
  String get shareCode => 'Code teilen';

  @override
  String joinMedoraFamily(String code) {
    return 'Tritt meiner Medora-Familie bei! Code: $code';
  }

  @override
  String get generateNewCode => 'Neuen Code generieren';

  @override
  String get members => 'Mitglieder';

  @override
  String get noMembersYet => 'Noch keine Mitglieder';

  @override
  String get unknown => 'Unbekannt';

  @override
  String get owner => 'Eigentümer';

  @override
  String get member => 'Mitglied';

  @override
  String get removeMember => 'Mitglied entfernen';

  @override
  String removeMemberConfirm(String name) {
    return '$name aus der Familie entfernen?';
  }

  @override
  String get remove => 'Entfernen';

  @override
  String get leaveFamily => 'Familie verlassen';

  @override
  String get leaveFamilyConfirm =>
      'Möchten Sie diese Familie wirklich verlassen? Sie haben keinen Zugriff mehr auf geteilte Medikamente.';

  @override
  String get leave => 'Verlassen';

  @override
  String get retry => 'Erneut versuchen';

  @override
  String error(String message) {
    return 'Fehler: $message';
  }

  @override
  String get appearance => 'Darstellung';

  @override
  String get darkMode => 'Dunkelmodus';

  @override
  String get darkModeLabel => 'Dunkel';

  @override
  String get lightMode => 'Hell';

  @override
  String get systemDefault => 'System';

  @override
  String get language => 'Sprache';

  @override
  String get lookingUpBarcode => 'Barcode wird gesucht…';

  @override
  String get autoFilledFromBarcode =>
      'Produkt gefunden — Felder automatisch ausgefüllt';

  @override
  String get barcodeNotFound =>
      'Produkt nicht gefunden — bitte manuell eingeben';

  @override
  String get editTreatment => 'Behandlung bearbeiten';

  @override
  String get treatmentUpdatedSuccessfully =>
      'Behandlung erfolgreich aktualisiert';

  @override
  String get updateTreatment => 'Behandlung aktualisieren';

  @override
  String get editPrescription => 'Verschreibung bearbeiten';

  @override
  String get prescriptionUpdated => 'Verschreibung aktualisiert';

  @override
  String get scheduleType => 'Zeitplanart';

  @override
  String get fixedInterval => 'Festes Intervall';

  @override
  String get timesPerDay => 'Mal pro Tag';

  @override
  String get specificTimes => 'Bestimmte Zeiten';

  @override
  String get morning => 'Morgens';

  @override
  String get noon => 'Mittags';

  @override
  String get evening => 'Abends';

  @override
  String get beforeSleep => 'Vor dem Schlafen';

  @override
  String get selectTimes => 'Zeiten auswählen';

  @override
  String everyXHours(int hours) {
    return 'Alle $hours Stunden';
  }

  @override
  String xTimesDaily(int count) {
    return '$count mal täglich';
  }

  @override
  String get save => 'Speichern';

  @override
  String get update => 'Aktualisieren';

  @override
  String get selectMedication => 'Medikament auswählen';

  @override
  String get results => 'Ergebnisse';

  @override
  String get searchByBarcode => 'Nach Code suchen';

  @override
  String get archiveTreatment => 'Behandlung archivieren';

  @override
  String archiveTreatmentConfirm(String name) {
    return '\"$name\" archivieren? Die Behandlung wird ins Archiv verschoben und kann später eingesehen werden.';
  }

  @override
  String get archive => 'Archivieren';

  @override
  String get archived => 'Archiviert';

  @override
  String get deletePrescription => 'Verschreibung löschen';

  @override
  String get deletePrescriptionConfirm =>
      'Möchten Sie diese Verschreibung wirklich löschen? Diese Aktion kann nicht rückgängig gemacht werden.';

  @override
  String get prescriptionDeleted => 'Verschreibung gelöscht';

  @override
  String get patientName => 'Patient';

  @override
  String get patientNameHint => 'z.B. Baby, Mama...';

  @override
  String get doseHistory => 'Dosisverlauf';

  @override
  String get noDoseHistory => 'Noch kein Dosisverlauf';

  @override
  String get medicationPhoto => 'Foto';

  @override
  String get addPhoto => 'Foto hinzufügen';

  @override
  String get changePhoto => 'Foto ändern';

  @override
  String get photoSource => 'Fotoquelle';

  @override
  String get camera => 'Kamera';

  @override
  String get gallery => 'Galerie';

  @override
  String forPatient(String name) {
    return 'Für: $name';
  }

  @override
  String get catPainkiller => 'Schmerzmittel';

  @override
  String get catAntibiotic => 'Antibiotikum';

  @override
  String get catAntihistamine => 'Antihistaminikum';

  @override
  String get catVitamin => 'Vitamin';

  @override
  String get catSupplement => 'Nahrungsergänzung';

  @override
  String get catColdFlu => 'Erkältung & Grippe';

  @override
  String get catDigestive => 'Verdauung';

  @override
  String get catSkinCare => 'Hautpflege';

  @override
  String get catEyeCare => 'Augenpflege';

  @override
  String get catFirstAid => 'Erste Hilfe';

  @override
  String get catOther => 'Sonstiges';

  @override
  String get activeIngredients => 'Wirkstoffe';

  @override
  String get symptomsField => 'Symptome / Anwendung';

  @override
  String get patientTagsField => 'Patient';

  @override
  String get addTag => 'Tag hinzufügen...';

  @override
  String get treatsSymptoms => 'Hilft bei';

  @override
  String get uncategorized => 'Ohne Kategorie';

  @override
  String get deactivatePrescription => 'Deaktivieren';

  @override
  String get prescriptionDeactivated => 'Verschreibung deaktiviert';

  @override
  String get reactivatePrescription => 'Reaktivieren';

  @override
  String get prescriptionReactivated => 'Verschreibung reaktiviert';

  @override
  String get locMedicineCabinet => 'Medizinschrank';

  @override
  String get locBathroom => 'Badezimmer';

  @override
  String get locKitchen => 'Küche';

  @override
  String get locBedroom => 'Schlafzimmer';

  @override
  String get locRefrigerator => 'Kühlschrank';

  @override
  String get locFirstAidKit => 'Erste-Hilfe-Kasten';

  @override
  String get locOther => 'Sonstiges';

  @override
  String get deleteAllData => 'Alle Daten löschen';

  @override
  String get deleteAllDataDesc =>
      'Alle Medikamente, Behandlungen, Dosen und Verschreibungen entfernen';

  @override
  String get deleteAllDataConfirm =>
      'Dies löscht ALLE Ihre Daten lokal und online dauerhaft. Geben Sie DELETE ein um zu bestätigen.';

  @override
  String get typeDeleteToConfirm => 'Geben Sie DELETE ein';

  @override
  String get allDataDeleted => 'Alle Daten wurden gelöscht';

  @override
  String get dangerZone => 'Gefahrenzone';

  @override
  String get treatmentPatientTags => 'Patient';

  @override
  String get treatmentSymptomTags => 'Symptome';

  @override
  String get searchTreatments => 'Behandlungen suchen…';

  @override
  String get all => 'Alle';

  @override
  String get noResults => 'Keine Ergebnisse gefunden';

  @override
  String get medicationDescription => 'Beschreibung';

  @override
  String get manufacturerLabel => 'Hersteller';

  @override
  String get formLabel => 'Darreichungsform';

  @override
  String get atcCodeLabel => 'ATC-Code';

  @override
  String get searchAifaByName => 'AIFA-Datenbank durchsuchen';

  @override
  String get quantityUnit => 'Einheit';

  @override
  String get unitPieces => 'Stück';

  @override
  String get unitPills => 'Pillen';

  @override
  String get unitTablets => 'Tabletten';

  @override
  String get unitCapsules => 'Kapseln';

  @override
  String get unitMl => 'ml';

  @override
  String get unitDrops => 'Tropfen';

  @override
  String get unitBustine => 'Beutel';

  @override
  String get unitAmpoules => 'Ampullen';

  @override
  String get unitSuppositories => 'Zäpfchen';

  @override
  String get unitPatches => 'Pflaster';

  @override
  String get autoDiminish => 'Bestand automatisch reduzieren';

  @override
  String get autoDiminishHint =>
      'Medikamentenmenge automatisch reduzieren, wenn eine Dosis eingenommen wird';

  @override
  String get unarchive => 'Dearchivieren';

  @override
  String get archivedMedications => 'Archivierte Medikamente';

  @override
  String get showArchived => 'Archiv anzeigen';

  @override
  String get signIn => 'Anmelden';

  @override
  String get signUp => 'Registrieren';

  @override
  String get createAccount => 'Konto erstellen';

  @override
  String get email => 'E-Mail';

  @override
  String get password => 'Passwort';

  @override
  String get continueAsGuest => 'Als Gast fortfahren';

  @override
  String get signOut => 'Abmelden';

  @override
  String get alreadyHaveAccount => 'Bereits ein Konto? Anmelden';

  @override
  String get dontHaveAccount => 'Noch kein Konto? Registrieren';

  @override
  String get useOfflineMode => 'Offline-Modus nutzen';
}
