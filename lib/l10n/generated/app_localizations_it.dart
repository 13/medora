// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get appTitle => 'Medora';

  @override
  String get navHome => 'Home';

  @override
  String get navMedications => 'Farmaci';

  @override
  String get navDoses => 'Dosi';

  @override
  String get navTreatments => 'Trattamenti';

  @override
  String get dashboard => 'Pannello';

  @override
  String get seeAll => 'Mostra tutto';

  @override
  String get todaysDoses => 'Dosi di oggi';

  @override
  String get noDosesScheduled => 'Nessuna dose programmata per oggi';

  @override
  String dosesProgress(int taken, int total, int pending) {
    return '$taken di $total assunte · $pending in attesa';
  }

  @override
  String get unableToLoadDoses => 'Impossibile caricare le dosi';

  @override
  String get addMedication => 'Aggiungi\nfarmaco';

  @override
  String get scanBarcode => 'Scansiona\ncodice';

  @override
  String get newTreatment => 'Nuovo\ntrattamento';

  @override
  String get expiringSoon => 'In scadenza';

  @override
  String get lowStock => 'Scorte basse';

  @override
  String get activeTreatments => 'Trattamenti attivi';

  @override
  String get allMedicationsWithinDate =>
      'Tutti i farmaci sono in corso di validità';

  @override
  String get allMedicationsWellStocked => 'Tutti i farmaci sono ben forniti';

  @override
  String get noActiveTreatments => 'Nessun trattamento attivo';

  @override
  String expiresInDays(int days) {
    return 'Scade tra $days giorni';
  }

  @override
  String get noExpirySet => 'Nessuna scadenza impostata';

  @override
  String remaining(int quantity) {
    return '$quantity rimanenti';
  }

  @override
  String startedOn(String date) {
    return 'Iniziato il $date';
  }

  @override
  String get medications => 'Farmaci';

  @override
  String get searchMedications => 'Cerca farmaci...';

  @override
  String get noMedicationsYet => 'Nessun farmaco ancora';

  @override
  String get addFirstMedication => 'Aggiungi il tuo primo farmaco per iniziare';

  @override
  String get addMedicationButton => 'Aggiungi farmaco';

  @override
  String get edit => 'Modifica';

  @override
  String get delete => 'Elimina';

  @override
  String get deleteMedication => 'Elimina farmaco';

  @override
  String deleteMedicationConfirm(String name) {
    return 'Sei sicuro di voler eliminare \"$name\"?';
  }

  @override
  String get cancel => 'Annulla';

  @override
  String get noExpiry => 'Nessuna scadenza';

  @override
  String get loadingMedications => 'Caricamento farmaci...';

  @override
  String get editMedication => 'Modifica farmaco';

  @override
  String get medicationNameLabel => 'Nome del farmaco *';

  @override
  String get pleaseEnterMedicationName => 'Inserisci il nome del farmaco';

  @override
  String get activeIngredient => 'Principio attivo';

  @override
  String get category => 'Categoria';

  @override
  String get quantityLabel => 'Quantità *';

  @override
  String get required => 'Obbligatorio';

  @override
  String get invalidNumber => 'Numero non valido';

  @override
  String get minStock => 'Scorta minima';

  @override
  String get purchaseDate => 'Data di acquisto';

  @override
  String get expiryDate => 'Data di scadenza';

  @override
  String get storageLocation => 'Luogo di conservazione';

  @override
  String get barcode => 'Codice a barre';

  @override
  String get notes => 'Note';

  @override
  String get updateMedication => 'Aggiorna farmaco';

  @override
  String get medicationUpdatedSuccessfully => 'Farmaco aggiornato con successo';

  @override
  String get medicationAddedSuccessfully => 'Farmaco aggiunto con successo';

  @override
  String errorLoadingMedication(String message) {
    return 'Errore nel caricamento del farmaco: $message';
  }

  @override
  String get selectDate => 'Seleziona data';

  @override
  String get medication => 'Farmaco';

  @override
  String get medicationNotFound => 'Farmaco non trovato';

  @override
  String get quantity => 'Quantità';

  @override
  String get details => 'Dettagli';

  @override
  String get minimumStock => 'Scorta minima';

  @override
  String get expired => 'Scaduto';

  @override
  String expiresInDaysShort(int days) {
    return 'Scade tra $days giorni';
  }

  @override
  String get valid => 'Valido';

  @override
  String quantityLeft(int quantity) {
    return '$quantity rimanenti';
  }

  @override
  String get treatments => 'Trattamenti';

  @override
  String get noTreatmentsYet => 'Nessun trattamento ancora';

  @override
  String get createTreatmentPlan =>
      'Crea un piano di trattamento per una malattia';

  @override
  String get addTreatment => 'Aggiungi trattamento';

  @override
  String get end => 'Termina';

  @override
  String get deleteTreatment => 'Elimina trattamento';

  @override
  String deleteTreatmentConfirm(String name) {
    return 'Eliminare \"$name\" e tutte le sue prescrizioni?';
  }

  @override
  String get active => 'Attivo';

  @override
  String get ended => 'Terminato';

  @override
  String get loadingTreatments => 'Caricamento trattamenti...';

  @override
  String get newTreatmentTitle => 'Nuovo trattamento';

  @override
  String get treatmentNameLabel => 'Nome del trattamento *';

  @override
  String get treatmentNameHint => 'es. Trattamento influenza';

  @override
  String get pleaseEnterTreatmentName => 'Inserisci il nome del trattamento';

  @override
  String get symptoms => 'Sintomi';

  @override
  String get symptomsHint => 'es. Febbre, mal di testa, mal di gola';

  @override
  String get startDateLabel => 'Data di inizio *';

  @override
  String get endDateLabel => 'Data di fine (opzionale)';

  @override
  String get selectEndDate => 'Seleziona data di fine';

  @override
  String get createTreatment => 'Crea trattamento';

  @override
  String get treatmentCreatedSuccessfully => 'Trattamento creato con successo';

  @override
  String get treatment => 'Trattamento';

  @override
  String get treatmentNotFound => 'Trattamento non trovato';

  @override
  String get endTreatment => 'Termina trattamento';

  @override
  String endTreatmentConfirm(String name) {
    return 'Terminare \"$name\"? Tutte le prescrizioni saranno disattivate.';
  }

  @override
  String get startDate => 'Data di inizio';

  @override
  String get endDate => 'Data di fine';

  @override
  String get ongoing => 'In corso';

  @override
  String get prescriptions => 'Prescrizioni';

  @override
  String get add => 'Aggiungi';

  @override
  String get noPrescriptionsYet => 'Nessuna prescrizione ancora';

  @override
  String get addPrescription => 'Aggiungi prescrizione';

  @override
  String get unknownMedication => 'Farmaco sconosciuto';

  @override
  String prescriptionSummary(String dosage, int hours, int days) {
    return '$dosage · ogni ${hours}h · $days giorni';
  }

  @override
  String get done => 'Completato';

  @override
  String errorLoadingPrescriptions(String message) {
    return 'Errore nel caricamento delle prescrizioni: $message';
  }

  @override
  String get medicationLabel => 'Farmaco *';

  @override
  String get dosageLabel => 'Dosaggio *';

  @override
  String get dosageHint => 'es. 400mg';

  @override
  String get intervalHoursLabel => 'Intervallo (ore)';

  @override
  String get durationDaysLabel => 'Durata (giorni)';

  @override
  String get todaysDosesTitle => 'Dosi di oggi';

  @override
  String get noDosesScheduledToday => 'Nessuna dose programmata per oggi';

  @override
  String get createTreatmentForDoses =>
      'Crea un trattamento e aggiungi prescrizioni per vedere le dosi qui';

  @override
  String get upcoming => 'Prossime';

  @override
  String get completed => 'Completate';

  @override
  String get taken => 'Assunta';

  @override
  String get pending => 'In attesa';

  @override
  String get skipped => 'Saltata';

  @override
  String get missed => 'Mancata';

  @override
  String get overdue => 'In ritardo';

  @override
  String get skip => 'Salta';

  @override
  String get take => 'Assumi';

  @override
  String get loadingDoses => 'Caricamento dosi...';

  @override
  String get scanBarcodeTitle => 'Scansiona codice AIC';

  @override
  String get pointCameraAtBarcode => 'Inquadra il codice AIC sulla confezione';

  @override
  String get enterBarcodeManually => 'Inserisci codice manualmente';

  @override
  String get enterBarcode => 'Inserisci codice AIC';

  @override
  String get barcodeNumber => 'Codice AIC';

  @override
  String get barcodeHint => 'es. A023834118';

  @override
  String get useBarcode => 'Cerca';

  @override
  String get scanBarcodeTooltip => 'Scansiona codice AIC';

  @override
  String get ocrDetectedCodes => 'Codici rilevati — tocca per cercare';

  @override
  String get ocrScanning => 'Ricerca codici AIC in corso…';

  @override
  String get settings => 'Impostazioni';

  @override
  String get about => 'Informazioni';

  @override
  String get appVersion => 'Versione';

  @override
  String get colorScheme => 'Schema colori';

  @override
  String get colorSchemeDesc => 'Scegli un colore di accento per l\'app';

  @override
  String get colorTeal => 'Verde acqua';

  @override
  String get colorBlue => 'Blu';

  @override
  String get colorIndigo => 'Indaco';

  @override
  String get colorPurple => 'Viola';

  @override
  String get colorPink => 'Rosa';

  @override
  String get colorRed => 'Rosso';

  @override
  String get colorOrange => 'Arancione';

  @override
  String get colorGreen => 'Verde';

  @override
  String get aifaDatabase => 'Database AIFA';

  @override
  String get aifaDatabaseDesc => 'Database farmaci italiani per ricerca codice';

  @override
  String aifaLastSync(String date) {
    return 'Ultimo aggiornamento: $date';
  }

  @override
  String get aifaNeverSynced => 'Non ancora scaricato';

  @override
  String get aifaSyncing => 'Download database in corso…';

  @override
  String aifaSyncSuccess(int count) {
    return 'Database aggiornato ($count farmaci)';
  }

  @override
  String get aifaSyncError => 'Download database fallito';

  @override
  String get syncAifaDatabase => 'Aggiorna database';

  @override
  String get notifications => 'Notifiche';

  @override
  String get enableNotifications => 'Abilita notifiche';

  @override
  String get receiveDoseReminders => 'Ricevi promemoria per le dosi';

  @override
  String get cancelAllReminders => 'Annulla tutti i promemoria';

  @override
  String get removePendingNotifications =>
      'Rimuovi tutte le notifiche in sospeso';

  @override
  String get cancelAllRemindersConfirm =>
      'Sei sicuro di voler annullare tutti i promemoria in sospeso?';

  @override
  String get no => 'No';

  @override
  String get yes => 'Sì';

  @override
  String get allRemindersCancelled => 'Tutti i promemoria annullati';

  @override
  String get dataAndSync => 'Dati e sincronizzazione';

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get connectedSyncsAutomatically =>
      'Connesso — i dati si sincronizzano automaticamente';

  @override
  String get usingLocalData => 'Dati locali — sincronizzazione quando online';

  @override
  String get syncNow => 'Sincronizza ora';

  @override
  String get syncIdle => 'Tocca per sincronizzare i dati con il cloud';

  @override
  String get syncing => 'Sincronizzazione...';

  @override
  String get syncSuccess => 'Sincronizzazione completata';

  @override
  String get syncError => 'Sincronizzazione fallita — tocca per riprovare';

  @override
  String get features => 'Funzionalità';

  @override
  String get familySharing => 'Condivisione familiare';

  @override
  String get shareCabinetWithFamily =>
      'Condividi il tuo armadietto dei medicinali con la famiglia';

  @override
  String get exportData => 'Esporta dati';

  @override
  String get exportAsCsvOrPdf => 'Esporta come CSV o PDF';

  @override
  String get exportDataTitle => 'Esporta dati';

  @override
  String get exportYourData => 'Esporta i tuoi dati';

  @override
  String get chooseWhatToExport => 'Scegli cosa esportare e il formato';

  @override
  String get include => 'Includi';

  @override
  String get fullMedicationInventory => 'Inventario completo dei farmaci';

  @override
  String get treatmentPlansAndHistory => 'Piani di trattamento e cronologia';

  @override
  String get doseLogs => 'Registri dosi';

  @override
  String get medicationIntakeRecords => 'Registri di assunzione farmaci';

  @override
  String get doseLogDateRange => 'Periodo registri dosi';

  @override
  String get from => 'Da';

  @override
  String get to => 'A';

  @override
  String get format => 'Formato';

  @override
  String get exporting => 'Esportazione...';

  @override
  String get exportAndShare => 'Esporta e condividi';

  @override
  String get noDataToExport => 'Nessun dato da esportare';

  @override
  String exportFailed(String error) {
    return 'Esportazione fallita: $error';
  }

  @override
  String get familySharingTitle => 'Condivisione familiare';

  @override
  String get loadingFamily => 'Caricamento famiglia...';

  @override
  String get noFamilyGroup => 'Nessun gruppo familiare';

  @override
  String get noFamilyDescription =>
      'Crea un gruppo familiare per condividere il tuo armadietto dei medicinali, o unisciti a uno esistente con un codice di invito.';

  @override
  String get createFamily => 'Crea famiglia';

  @override
  String get joinWithCode => 'Unisciti con codice';

  @override
  String get familyName => 'Nome famiglia';

  @override
  String get familyNameHint => 'es. Famiglia Rossi';

  @override
  String get yourName => 'Il tuo nome';

  @override
  String get yourNameHint => 'es. Marco';

  @override
  String get create => 'Crea';

  @override
  String get joinFamily => 'Unisciti alla famiglia';

  @override
  String get inviteCode => 'Codice di invito';

  @override
  String get inviteCodeHint => 'es. ABC123';

  @override
  String get join => 'Unisciti';

  @override
  String get copyCode => 'Copia codice';

  @override
  String get codeCopied => 'Codice copiato negli appunti';

  @override
  String get shareCode => 'Condividi codice';

  @override
  String joinMedoraFamily(String code) {
    return 'Unisciti alla mia famiglia Medora! Codice: $code';
  }

  @override
  String get generateNewCode => 'Genera nuovo codice';

  @override
  String get members => 'Membri';

  @override
  String get noMembersYet => 'Nessun membro ancora';

  @override
  String get unknown => 'Sconosciuto';

  @override
  String get owner => 'Proprietario';

  @override
  String get member => 'Membro';

  @override
  String get removeMember => 'Rimuovi membro';

  @override
  String removeMemberConfirm(String name) {
    return 'Rimuovere $name dalla famiglia?';
  }

  @override
  String get remove => 'Rimuovi';

  @override
  String get leaveFamily => 'Lascia la famiglia';

  @override
  String get leaveFamilyConfirm =>
      'Sei sicuro di voler lasciare questa famiglia? Non avrai più accesso ai farmaci condivisi.';

  @override
  String get leave => 'Lascia';

  @override
  String get retry => 'Riprova';

  @override
  String error(String message) {
    return 'Errore: $message';
  }

  @override
  String get appearance => 'Aspetto';

  @override
  String get darkMode => 'Modalità scura';

  @override
  String get darkModeLabel => 'Scuro';

  @override
  String get lightMode => 'Chiaro';

  @override
  String get systemDefault => 'Sistema';

  @override
  String get language => 'Lingua';

  @override
  String get lookingUpBarcode => 'Ricerca del codice a barre…';

  @override
  String get autoFilledFromBarcode =>
      'Prodotto trovato — campi compilati automaticamente';

  @override
  String get barcodeNotFound =>
      'Prodotto non trovato — inserisci i dati manualmente';

  @override
  String get editTreatment => 'Modifica trattamento';

  @override
  String get treatmentUpdatedSuccessfully =>
      'Trattamento aggiornato con successo';

  @override
  String get updateTreatment => 'Aggiorna trattamento';

  @override
  String get editPrescription => 'Modifica prescrizione';

  @override
  String get prescriptionUpdated => 'Prescrizione aggiornata';

  @override
  String get scheduleType => 'Tipo di programma';

  @override
  String get fixedInterval => 'Intervallo fisso';

  @override
  String get timesPerDay => 'Volte al giorno';

  @override
  String get specificTimes => 'Orari specifici';

  @override
  String get morning => 'Mattina';

  @override
  String get noon => 'Mezzogiorno';

  @override
  String get evening => 'Sera';

  @override
  String get beforeSleep => 'Prima di dormire';

  @override
  String get selectTimes => 'Seleziona orari';

  @override
  String everyXHours(int hours) {
    return 'Ogni $hours ore';
  }

  @override
  String xTimesDaily(int count) {
    return '$count volte al giorno';
  }

  @override
  String get save => 'Salva';

  @override
  String get update => 'Aggiorna';

  @override
  String get selectMedication => 'Seleziona farmaco';

  @override
  String get results => 'risultati';

  @override
  String get searchByBarcode => 'Cerca per codice';

  @override
  String get archiveTreatment => 'Archivia trattamento';

  @override
  String archiveTreatmentConfirm(String name) {
    return 'Archiviare \"$name\"? Verrà spostato nell\'archivio e potrà essere consultato in seguito.';
  }

  @override
  String get archive => 'Archivia';

  @override
  String get archived => 'Archiviato';

  @override
  String get deletePrescription => 'Elimina prescrizione';

  @override
  String get deletePrescriptionConfirm =>
      'Sei sicuro di voler eliminare questa prescrizione? Questa azione non può essere annullata.';

  @override
  String get prescriptionDeleted => 'Prescrizione eliminata';

  @override
  String get patientName => 'Paziente';

  @override
  String get patientNameHint => 'es. Bambino, Mamma...';

  @override
  String get doseHistory => 'Storico dosi';

  @override
  String get noDoseHistory => 'Nessuno storico dosi';

  @override
  String get medicationPhoto => 'Foto';

  @override
  String get addPhoto => 'Aggiungi foto';

  @override
  String get changePhoto => 'Cambia foto';

  @override
  String get photoSource => 'Fonte foto';

  @override
  String get camera => 'Fotocamera';

  @override
  String get gallery => 'Galleria';

  @override
  String forPatient(String name) {
    return 'Per: $name';
  }

  @override
  String get catPainkiller => 'Antidolorifico';

  @override
  String get catAntibiotic => 'Antibiotico';

  @override
  String get catAntihistamine => 'Antistaminico';

  @override
  String get catVitamin => 'Vitamina';

  @override
  String get catSupplement => 'Integratore';

  @override
  String get catColdFlu => 'Raffreddore & Influenza';

  @override
  String get catDigestive => 'Digestivo';

  @override
  String get catSkinCare => 'Cura della pelle';

  @override
  String get catEyeCare => 'Cura degli occhi';

  @override
  String get catFirstAid => 'Primo soccorso';

  @override
  String get catOther => 'Altro';

  @override
  String get activeIngredients => 'Principi attivi';

  @override
  String get symptomsField => 'Sintomi / Uso';

  @override
  String get patientTagsField => 'Paziente';

  @override
  String get addTag => 'Aggiungi tag...';

  @override
  String get treatsSymptoms => 'Cura';

  @override
  String get uncategorized => 'Senza categoria';

  @override
  String get deactivatePrescription => 'Disattiva';

  @override
  String get prescriptionDeactivated => 'Prescrizione disattivata';

  @override
  String get reactivatePrescription => 'Riattiva';

  @override
  String get prescriptionReactivated => 'Prescrizione riattivata';

  @override
  String get locMedicineCabinet => 'Armadietto dei medicinali';

  @override
  String get locBathroom => 'Bagno';

  @override
  String get locKitchen => 'Cucina';

  @override
  String get locBedroom => 'Camera da letto';

  @override
  String get locRefrigerator => 'Frigorifero';

  @override
  String get locFirstAidKit => 'Kit di primo soccorso';

  @override
  String get locOther => 'Altro';

  @override
  String get deleteAllData => 'Elimina tutti i dati';

  @override
  String get deleteAllDataDesc =>
      'Rimuovi tutti i medicinali, trattamenti, dosi e prescrizioni';

  @override
  String get deleteAllDataConfirm =>
      'Questo eliminerà TUTTI i tuoi dati locali e online in modo permanente. Digita DELETE per confermare.';

  @override
  String get typeDeleteToConfirm => 'Digita DELETE per confermare';

  @override
  String get allDataDeleted => 'Tutti i dati sono stati eliminati';

  @override
  String get dangerZone => 'Zona pericolosa';

  @override
  String get treatmentPatientTags => 'Paziente';

  @override
  String get treatmentSymptomTags => 'Sintomi';

  @override
  String get searchTreatments => 'Cerca trattamenti…';

  @override
  String get all => 'Tutti';

  @override
  String get noResults => 'Nessun risultato trovato';

  @override
  String get medicationDescription => 'Descrizione';

  @override
  String get manufacturerLabel => 'Produttore';

  @override
  String get formLabel => 'Forma';

  @override
  String get atcCodeLabel => 'Codice ATC';

  @override
  String get searchAifaByName => 'Cerca nel database AIFA';

  @override
  String get quantityUnit => 'Unità';

  @override
  String get unitPieces => 'Pezzi';

  @override
  String get unitPills => 'Pillole';

  @override
  String get unitTablets => 'Compresse';

  @override
  String get unitCapsules => 'Capsule';

  @override
  String get unitMl => 'ml';

  @override
  String get unitDrops => 'Gocce';

  @override
  String get unitBustine => 'Bustine';

  @override
  String get unitAmpoules => 'Fiale';

  @override
  String get unitSuppositories => 'Supposte';

  @override
  String get unitPatches => 'Cerotti';

  @override
  String get autoDiminish => 'Riduzione automatica scorte';

  @override
  String get autoDiminishHint =>
      'Riduce automaticamente la quantità del farmaco quando si prende una dose';

  @override
  String get unarchive => 'Ripristina';

  @override
  String get archivedMedications => 'Farmaci archiviati';

  @override
  String get showArchived => 'Mostra archiviati';

  @override
  String get signIn => 'Accedi';

  @override
  String get signUp => 'Registrati';

  @override
  String get createAccount => 'Crea account';

  @override
  String get email => 'Email';

  @override
  String get password => 'Password';

  @override
  String get continueAsGuest => 'Continua come ospite';

  @override
  String get signOut => 'Disconnetti';

  @override
  String get alreadyHaveAccount => 'Hai già un account? Accedi';

  @override
  String get dontHaveAccount => 'Non hai un account? Registrati';

  @override
  String get useOfflineMode => 'Usa modalità offline';
}
