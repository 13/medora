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
  String get appDescription =>
      'Medora - Gestore dell\'armadietto dei medicinali di casa';

  @override
  String get navHome => 'Dashboard';

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
  String get statExpiring => 'In scadenza';

  @override
  String get statLowStock => 'Scorte basse';

  @override
  String get statTreatments => 'Trattamenti';

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
  String get sectionBasics => 'Dati principali';

  @override
  String get sectionStock => 'Scorte e conservazione';

  @override
  String get sectionDetails => 'Dettagli';

  @override
  String minStockShort(int n) {
    return 'min $n';
  }

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
  String numPrescriptions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count prescrizioni',
      one: '1 prescrizione',
      zero: 'Nessuna prescrizione',
    );
    return '$_temp0';
  }

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
  String doseTimesPreview(String times) {
    return 'Dosi alle $times';
  }

  @override
  String get changeMedicationConfirm =>
      'Cambiare il farmaco rigenera le dosi in sospeso. Continuare?';

  @override
  String get intervalRange => 'L\'intervallo deve essere tra 1 e 48 ore';

  @override
  String get durationRange => 'La durata deve essere tra 1 e 365 giorni';

  @override
  String get selectAtLeastOneTime => 'Seleziona almeno un orario';

  @override
  String get todaysDosesTitle => 'Dosi di oggi';

  @override
  String get noDosesScheduledToday => 'Nessuna dose programmata per oggi';

  @override
  String get noDosesForThisDay => 'Nessuna dose in questo giorno';

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
  String takenAt(String time) {
    return 'Assunta alle $time';
  }

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
  String get nextDose => 'Prossima dose';

  @override
  String get allDosesDone => 'Tutte le dosi di oggi sono state prese';

  @override
  String get doseTaken => 'Assunta';

  @override
  String get doseSkipped => 'Saltata';

  @override
  String get undo => 'Annulla';

  @override
  String get takeAllDue => 'Prendi tutte le dosi dovute';

  @override
  String dosesDueNow(int count) {
    return '$count dosi dovute';
  }

  @override
  String dosesTakenCount(int count) {
    return '$count dosi prese';
  }

  @override
  String get scanBarcodeTitle => 'Scansiona codice AIC';

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
  String get scanTakePhoto => 'Scatta foto';

  @override
  String get scanFromGallery => 'Scegli dalla galleria';

  @override
  String get scanRetake => 'Rifai foto';

  @override
  String get scanRecognizing => 'Riconoscimento del testo…';

  @override
  String get scanChooseCode => 'Tocca il codice da usare';

  @override
  String get scanAicCodes => 'Codici AIC';

  @override
  String get scanSupplementCodes =>
      'Codici integratori (Ministero della Salute)';

  @override
  String get scanBarcodes => 'Codici a barre (EAN)';

  @override
  String get scanOtherNumbers => 'Altri numeri';

  @override
  String get scanNoCodeFound =>
      'Nessun codice trovato. Scatta più da vicino o inserisci il codice.';

  @override
  String get scanSelectArea => 'Seleziona area';

  @override
  String get scanSelectCentre => 'Seleziona il centro';

  @override
  String get scanRescanArea => 'Scansiona selezione';

  @override
  String get scanSelectAreaHint =>
      'Trascina un riquadro attorno al codice, poi scansiona la selezione.';

  @override
  String get scanRescanNothingNew => 'Nessun nuovo codice in quell\'area.';

  @override
  String get scanRescanTooSmall =>
      'Questa selezione è troppo piccola per la scansione. Disegna un riquadro più grande.';

  @override
  String get scanCaptureHint =>
      'Fotografa la confezione con il codice AIC ben leggibile';

  @override
  String get scanMedicationInCabinet => 'Già nel tuo armadietto';

  @override
  String get supplementRegister => 'Registro integratori';

  @override
  String get supplementRegisterHint =>
      'Registro del Ministero della Salute per i codici degli integratori (COD MINSAN)';

  @override
  String supplementRegisterUpdated(String date) {
    return 'Aggiornato al $date';
  }

  @override
  String get supplementRegisterUpdate => 'Aggiorna registro';

  @override
  String get supplementRegisterDownload => 'Scarica';

  @override
  String registerStale(int days) {
    return 'Aggiornato $days giorni fa';
  }

  @override
  String get registerStaleUnknown =>
      'Età sconosciuta — aggiornamento consigliato';

  @override
  String get registerUpdateNow => 'Aggiorna ora';

  @override
  String get supplementRegisterDownloading => 'Download registro in corso…';

  @override
  String supplementRegisterSyncSuccess(int count) {
    return 'Registro aggiornato ($count prodotti)';
  }

  @override
  String get supplementRegisterDownloadPrompt =>
      'I codici degli integratori vengono cercati nel registro del Ministero della Salute. Scaricarlo ora (circa 2 MB)? Serve una connessione a internet.';

  @override
  String get supplementNotFound =>
      'Integratore non trovato nel registro — inserisci i dati manualmente';

  @override
  String get supplementSelectProduct => 'Seleziona prodotto';

  @override
  String scanAlternativeCodeConfirm(
    String read,
    String code,
    String product,
    String company,
  ) {
    return 'Codice $read non trovato. Intendevi $code: $product ($company)?';
  }

  @override
  String scanAlternativeCodeConfirmNoCompany(
    String read,
    String code,
    String product,
  ) {
    return 'Codice $read non trovato. Intendevi $code: $product?';
  }

  @override
  String get scanAlternativeCodeUse => 'Usa';

  @override
  String get settings => 'Impostazioni';

  @override
  String get about => 'Informazioni';

  @override
  String get appVersion => 'Versione';

  @override
  String get buildNumber => 'Build';

  @override
  String get buildDate => 'Creato';

  @override
  String get buildCommit => 'Commit';

  @override
  String get buildChannel => 'Canale';

  @override
  String get channelRelease => 'Release';

  @override
  String get channelCi => 'CI';

  @override
  String get channelDev => 'Versione di sviluppo';

  @override
  String get copiedToClipboard => 'Copiato';

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
  String get aifaDatabaseHint =>
      'Banca dati italiana dei farmaci per la ricerca per codice';

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
  String get stockAndExpiryReminders => 'Promemoria scorte e scadenza';

  @override
  String stockAndExpiryRemindersHint(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'Avvisa quando un farmaco sta finendo o scade entro $days giorni',
      one: 'Avvisa quando un farmaco sta finendo o scade entro 1 giorno',
    );
    return '$_temp0';
  }

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
  String get notificationsBlocked =>
      'Le notifiche sono bloccate. Consentile a Medora nelle impostazioni di sistema.';

  @override
  String get dataSection => 'Dati';

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
  String get syncPartial => 'Completata con alcuni errori';

  @override
  String get syncNever => 'Non ancora sincronizzato';

  @override
  String lastSyncSummary(
    String time,
    int pushed,
    int pulled,
    int deleted,
    int failed,
  ) {
    return 'Ultima sincronizzazione $time: $pushed inviati, $pulled ricevuti, $deleted eliminati, $failed falliti';
  }

  @override
  String get syncFailedItems => 'Elementi non riusciti';

  @override
  String syncSkippedBackoff(int n) {
    return '$n in attesa di riprovare';
  }

  @override
  String get discardLocalChange => 'Scarta la modifica locale';

  @override
  String get discardLocalChangeHint =>
      'Sostituisce la modifica non sincronizzata con la copia sul server';

  @override
  String get ok => 'OK';

  @override
  String get advanced => 'Avanzate';

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
  String get exportAndShare => 'Esporta e condivi';

  @override
  String get noDataToExport => 'Nessun dato da esportare';

  @override
  String exportFailed(String error) {
    return 'Esportazione fallita: $error';
  }

  @override
  String wipeFailed(String error) {
    return 'Impossibile eliminare i dati locali: $error';
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
  String get afternoon => 'Pomeriggio';

  @override
  String get evening => 'Sera';

  @override
  String get night => 'Notte';

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
  String get searchSupplementByName => 'Cerca nel registro integratori';

  @override
  String get supplementSearchHint => 'Nome del prodotto';

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
  String get signOut => 'Disconnetti';

  @override
  String get alreadyHaveAccount => 'Hai già un account? Accedi';

  @override
  String get dontHaveAccount => 'Non hai un account? Registrati';

  @override
  String get forcePush => 'Forza invio';

  @override
  String get forcePull => 'Forza ricezione';

  @override
  String get forcePushTitle => 'Force Push to Cloud';

  @override
  String get forcePullTitle => 'Force Pull from Cloud';

  @override
  String get forcePushConfirm =>
      'Questo sovrascriverà tutti i dati in Supabase con i tuoi dati locali. Questa azione non può essere annullata. Continuare?';

  @override
  String get forcePullConfirm =>
      'Questa operazione sostituisce tutto ciò che è su questo dispositivo con i dati di Supabase. Le modifiche locali non ancora caricate andranno perse in modo irreversibile. Continuare?';

  @override
  String get foreignDataTitle => 'Dati di un altro account';

  @override
  String get foreignDataBody =>
      'Questo dispositivo contiene dati salvati con un altro account. Vuoi caricarli e unirli a questo account oppure eliminarli dal dispositivo?';

  @override
  String get foreignDataMerge => 'Carica e unisci';

  @override
  String get foreignDataDelete => 'Elimina i dati locali';

  @override
  String get continueLabel => 'Continua';

  @override
  String get daysLabel => 'Giorni';

  @override
  String get leftLabel => 'Rimanenti';

  @override
  String get notificationChannelName => 'Promemoria dosi';

  @override
  String get notificationChannelDescription =>
      'Promemoria per le dosi di farmaci programmate';

  @override
  String get notificationTicker => 'Promemoria farmaco';

  @override
  String notificationReminderTimeFor(String medication) {
    return 'È ora di assumere $medication';
  }

  @override
  String notificationReminderInMinutes(String medication, int minutes) {
    return 'Promemoria: $medication tra $minutes min';
  }

  @override
  String notificationReminderBody(String dosage) {
    return '$dosage — Tocca per registrare la dose';
  }

  @override
  String get notificationExpiryTitle => 'In scadenza';

  @override
  String notificationExpiryBody(String name, int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$name scade tra $days giorni',
      one: '$name scade domani',
      zero: '$name scade oggi',
    );
    return '$_temp0';
  }

  @override
  String get notificationLowStockTitle => 'Scorte in esaurimento';

  @override
  String notificationLowStockBody(String name, int quantity) {
    String _temp0 = intl.Intl.pluralLogic(
      quantity,
      locale: localeName,
      other: '$name: ne restano $quantity',
      one: '$name: ne resta 1',
      zero: '$name: esaurito',
    );
    return '$_temp0';
  }

  @override
  String get useOnThisDevice => 'Usa Medora su questo dispositivo';

  @override
  String get useOnThisDeviceDesc =>
      'I tuoi dati restano su questo dispositivo. Potrai attivare la sincronizzazione cloud dalle Impostazioni.';

  @override
  String get orSignInForCloud =>
      'Oppure accedi per sincronizzare tra dispositivi';

  @override
  String get cloudSync => 'Sincronizzazione cloud';

  @override
  String cloudSyncOn(String email) {
    return 'Attiva — accesso come $email';
  }

  @override
  String get cloudSyncOff =>
      'Disattiva — i dati sono salvati solo su questo dispositivo';

  @override
  String get cloudSyncUnavailable => 'Non configurato — tocca Configura';

  @override
  String get turnOnCloudSync => 'Attiva sincronizzazione cloud';

  @override
  String get turnOffCloudSync => 'Disattiva sincronizzazione cloud';

  @override
  String get localOnlyMode => 'Solo locale';

  @override
  String get unlockMedora => 'Sblocca Medora';

  @override
  String get biometricNotEnrolled =>
      'Nessun dato biometrico o blocco schermo configurato — impostalo nelle impostazioni di sistema';

  @override
  String get biometricLockedOut => 'Troppi tentativi — riprova più tardi';

  @override
  String get biometricNotAvailable =>
      'Lo sblocco biometrico non è disponibile su questo dispositivo';

  @override
  String get biometricFailed => 'Sblocco non riuscito';

  @override
  String get disableAppLock => 'Disattiva il blocco dell\'app';

  @override
  String get cloudRequiredForFamily =>
      'La condivisione familiare richiede la sincronizzazione cloud. Attivala nelle Impostazioni.';

  @override
  String get invalidEmail => 'Inserisci un indirizzo email valido';

  @override
  String get passwordTooShort => 'La password deve avere almeno 6 caratteri';

  @override
  String get turnOn => 'Attiva';

  @override
  String get turnOff => 'Disattiva';

  @override
  String get featureUnavailableOnPlatform =>
      'Questa funzione non è disponibile su questo dispositivo.';

  @override
  String get missedGracePeriod => 'Segna come saltata dopo';

  @override
  String get missedGracePeriodDesc =>
      'Le dosi in sospeso più vecchie vengono segnate come saltate all\'apertura dell\'app';

  @override
  String minutesShort(int minutes) {
    return '$minutes min';
  }

  @override
  String hoursShort(int hours) {
    return '$hours h';
  }

  @override
  String get keepLocalData => 'Mantieni i miei dati su questo dispositivo';

  @override
  String get wipeLocalData => 'Elimina i miei dati da questo dispositivo';

  @override
  String get turnOffCloudSyncChoice =>
      'Verrai disconnesso. Cosa fare con i dati salvati su questo dispositivo?';

  @override
  String get securitySection => 'Sicurezza';

  @override
  String get fingerprintUnlock => 'Sblocco con impronta';

  @override
  String get fingerprintUnlockDesc =>
      'Usa la biometria per proteggere i tuoi dati';

  @override
  String get undoTaken => 'Annulla assunzione';

  @override
  String get continueAction => 'Continua';

  @override
  String get today => 'Oggi';

  @override
  String get yesterday => 'Ieri';

  @override
  String get tomorrow => 'Domani';

  @override
  String get date => 'Data';

  @override
  String get clear => 'Cancella';

  @override
  String get genericError => 'Qualcosa è andato storto';

  @override
  String errorWithDetails(String details) {
    return 'Qualcosa è andato storto: $details';
  }

  @override
  String deleteDataFailed(String details) {
    return 'Impossibile eliminare i dati: $details';
  }

  @override
  String get exportNotSupportedOnWeb =>
      'L\'esportazione non è ancora disponibile nel browser.';

  @override
  String get exportReportTitle => 'Rapporto Medora';

  @override
  String get exportSummary => 'Riepilogo dell\'armadietto dei medicinali';

  @override
  String get exportDoseRecords => 'Registro delle dosi';

  @override
  String get name => 'Nome';

  @override
  String get dosage => 'Dosaggio';

  @override
  String get colActiveIngredient => 'Principio attivo';

  @override
  String get colMinStock => 'Scorta minima';

  @override
  String get colScheduled => 'Programmato';

  @override
  String get colTaken => 'Assunto';

  @override
  String get colStatus => 'Stato';

  @override
  String get yesLabel => 'Sì';

  @override
  String get noLabel => 'No';

  @override
  String get onboardingCabinetTitle => 'Il tuo armadietto';

  @override
  String get onboardingCabinetBody =>
      'Aggiungi i medicinali che hai in casa. Medora tiene traccia di quantità e scadenza per te.';

  @override
  String get onboardingTreatmentsTitle => 'Trattamenti';

  @override
  String get onboardingTreatmentsBody =>
      'Raggruppa i medicinali in un trattamento con un programma di chi prende cosa e quando.';

  @override
  String get onboardingDosesTitle => 'Dosi quotidiane';

  @override
  String get onboardingDosesBody =>
      'Ogni giorno mostra cosa è previsto. Tocca Prendi oppure lasciati avvisare dai promemoria.';

  @override
  String get onboardingNext => 'Avanti';

  @override
  String get onboardingDone => 'Fatto';

  @override
  String get checkForUpdates => 'Cerca aggiornamenti';

  @override
  String get checkingForUpdates => 'Ricerca aggiornamenti…';

  @override
  String get upToDate => 'Aggiornato';

  @override
  String updateAvailable(String version) {
    return 'Aggiornamento disponibile: $version';
  }

  @override
  String get updateDownload => 'Scarica';

  @override
  String get updateInstall => 'Installa';

  @override
  String get updateLater => 'Più tardi';

  @override
  String get updateReleaseNotes => 'Novità';

  @override
  String updatePublished(String date) {
    return 'Pubblicato il $date';
  }

  @override
  String updateBannerTitle(String version) {
    return 'Medora $version è disponibile';
  }

  @override
  String get updateView => 'Mostra';

  @override
  String get updateFailed => 'Impossibile cercare aggiornamenti';

  @override
  String get updateChecksumFailed => 'Impossibile verificare il download';

  @override
  String get updateNoAsset =>
      'Nessun pacchetto di installazione per questo dispositivo';

  @override
  String get updateCancel => 'Annulla il download';

  @override
  String get updateInstallExplainTitle => 'Installa l\'aggiornamento';

  @override
  String get updateInstallExplainBody =>
      'Android ti chiederà di consentire a Medora di installare app, poi aprirà il programma di installazione. I tuoi dati restano sul dispositivo.';

  @override
  String get updateShowMore => 'Mostra altro';

  @override
  String get updateShowLess => 'Mostra meno';

  @override
  String get backupData => 'Backup dei dati';

  @override
  String get backupDataHint =>
      'Salva tutto in un file JSON non cifrato — conservalo in un luogo sicuro';

  @override
  String get backupAction => 'Esegui backup';

  @override
  String backupIncludePhotos(int count, String megabytes) {
    return 'Includi le foto ($count file, ~$megabytes MB)';
  }

  @override
  String get backupPhotosTooLarge =>
      'Sono molte foto — escluderle mantiene il backup abbastanza piccolo da condividere.';

  @override
  String get restoreBackup => 'Ripristina da backup';

  @override
  String get restoreBackupHint => 'Rileggi un file di backup nell\'app';

  @override
  String get restoreAction => 'Ripristina';

  @override
  String get restoreReplace => 'Sostituisci tutto';

  @override
  String get restoreMerge => 'Unisci a questo dispositivo';

  @override
  String get restoreReplaceWarning =>
      'Tutto ciò che è su questo dispositivo viene prima eliminato e sostituito dal backup.';

  @override
  String restoreSummary(String created, int rows, int photos) {
    return 'Creato $created · $rows righe · $photos foto';
  }

  @override
  String get restoreInProgress => 'Ripristino in corso…';

  @override
  String restoreDone(int rows) {
    return 'Ripristinate $rows righe';
  }

  @override
  String get backupNotABackup => 'Questo file non è un backup di Medora.';

  @override
  String get backupNewerVersion =>
      'Questo backup proviene da una versione più recente di Medora. Aggiorna l\'app e riprova.';

  @override
  String get backupCorrupt =>
      'Impossibile leggere questo backup. Non è stato modificato nulla.';

  @override
  String get configureCloud => 'Configura la sincronizzazione cloud';

  @override
  String get cloudConfiguration => 'Configurazione cloud';

  @override
  String get configure => 'Configura';

  @override
  String get cloudConfiguredOnDevice => 'Configurato su questo dispositivo';

  @override
  String get cloudConfiguredFromBuild => 'Configurato da questa build';

  @override
  String get cloudRestartRequired =>
      'Riavvia Medora per applicare le nuove impostazioni cloud';

  @override
  String get cloudConfigIntro =>
      'Inserisci l\'URL e la chiave del tuo progetto Supabase. Restano salvati solo su questo dispositivo.';

  @override
  String get cloudProjectUrl => 'URL del progetto';

  @override
  String get cloudProjectUrlHint => 'https://tuoprogetto.supabase.co';

  @override
  String get cloudAnonKey => 'Chiave anon o publishable';

  @override
  String get cloudKeyStored => 'Chiave salvata su questo dispositivo';

  @override
  String get cloudKeyReplace => 'Sostituisci';

  @override
  String get paste => 'Incolla';

  @override
  String get cloudTestConnection => 'Prova la connessione';

  @override
  String get cloudTestOk => 'Il progetto risponde — i valori sono corretti';

  @override
  String get cloudTestFailed =>
      'Impossibile raggiungere il progetto con questi valori';

  @override
  String get cloudProbeBadKey =>
      'Raggiungibile, ma la chiave è stata rifiutata';

  @override
  String get cloudProbeTimeout => 'Il progetto non ha risposto in tempo';

  @override
  String cloudProbeHttpError(int code) {
    return 'Il progetto ha risposto con HTTP $code';
  }

  @override
  String get cloudInvalidUrl =>
      'Inserisci l\'URL completo del progetto, che inizia con https://';

  @override
  String get cloudKeyRequired =>
      'Inserisci la chiave anon o publishable del progetto';

  @override
  String get cloudConfigSaved =>
      'La sincronizzazione cloud è pronta — attivala qui sopra';

  @override
  String get cloudConfigCleared =>
      'Configurazione cloud rimossa da questo dispositivo';
}
