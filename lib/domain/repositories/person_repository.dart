/// Medora - Person Repository Interface
library;

import 'package:medora/core/result.dart';
import 'package:medora/domain/entities/person.dart';

abstract class PersonRepository {
  Future<Result<List<Person>>> getPersons();
  Future<Result<Person?>> getByTaxCode(String taxCode);

  /// Adds or updates [person].
  Future<Result<Person>> savePerson(Person person);
  Future<Result<void>> deletePerson(String id);
}
