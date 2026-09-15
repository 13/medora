import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/medication.dart';
import 'package:medora/domain/repositories/medication_repository.dart';

/// A [MedicationRepository] that serves [medications] happily but fails every
/// mutation with [error] — used to exercise the screens' error handling.
class FailingMedicationRepo implements MedicationRepository {
  FailingMedicationRepo({this.medications = const [], this.error = 'db down'});

  final List<Medication> medications;
  final String error;

  Result<T> _fail<T>() => Result<T>.failure(error);

  @override
  Future<Result<List<Medication>>> getMedications() async =>
      Result.success(medications);

  @override
  Future<Result<Medication>> getMedicationById(String id) async {
    final match = medications.where((m) => m.id == id).firstOrNull;
    return match == null ? _fail() : Result.success(match);
  }

  @override
  Future<Result<List<Medication>>> searchMedications(String query) async =>
      Result.success(medications);

  @override
  Future<Result<List<Medication>>> getExpiringSoon({int days = 30}) async =>
      const Result.success([]);

  @override
  Future<Result<List<Medication>>> getLowStock() async =>
      const Result.success([]);

  @override
  Future<Result<Medication?>> getMedicationByBarcode(String barcode) async =>
      const Result.success(null);

  @override
  Future<Result<List<Medication>>> getArchivedMedications() async =>
      const Result.success([]);

  @override
  Future<Result<Medication>> addMedication(Medication medication) async =>
      _fail();

  @override
  Future<Result<Medication>> updateMedication(Medication medication) async =>
      _fail();

  @override
  Future<Result<void>> deleteMedication(String id) async => _fail();

  @override
  Future<Result<Medication>> updateQuantity(String id, int delta) async =>
      _fail();

  @override
  Future<Result<void>> archiveMedication(String id) async => _fail();

  @override
  Future<Result<void>> unarchiveMedication(String id) async => _fail();
}
