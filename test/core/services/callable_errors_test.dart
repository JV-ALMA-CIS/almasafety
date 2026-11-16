import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jva_safety/core/errors/app_exception.dart';
import 'package:jva_safety/core/services/callable_errors.dart';
import 'package:jva_safety/features/safety_learning/data/worker_learning_service.dart';

FirebaseFunctionsException callableError(String code, [String? message]) =>
    FirebaseFunctionsException(code: code, message: message ?? '');

void main() {
  group('missingServerFunction', () {
    test('a function the server does not have needs an update', () {
      for (final e in [
        callableError('not-found', 'NOT_FOUND'),
        callableError('not-found', 'Not Found'),
        callableError('not-found'),
        callableError('unimplemented', 'UNIMPLEMENTED'),
      ]) {
        final mapped = missingServerFunction(e, 'Quiz counts');
        expect(mapped, isA<ServerUpdateRequiredException>(), reason: e.code);
        expect(mapped!.message, contains('needs the latest server update'));
      }
    });

    test('the browser\'s blocked call to a missing function says the server '
        'MAY need the update', () {
      final mapped = missingServerFunction(
        callableError('internal', 'internal'),
        'Quiz counts',
      );
      expect(mapped, isA<ServerUpdateRequiredException>());
      expect(mapped!.message, contains('may need the latest update'));
    });

    test('a refusal the server sent on purpose is never mistaken for it', () {
      for (final e in [
        callableError('not-found', 'That learning item is not available.'),
        callableError('internal', 'Firestore write failed.'),
        callableError('permission-denied', 'PERMISSION_DENIED'),
        callableError('unavailable'),
        callableError('failed-precondition', 'This learning item has no quiz.'),
      ]) {
        expect(missingServerFunction(e, 'Quiz counts'), isNull, reason: e.code);
      }
    });
  });

  group('WorkerLearningService.quizLoadError', () {
    test('an older server refusing a non-required quiz needs an update — '
        'not a permission problem', () {
      final mapped = WorkerLearningService.quizLoadError(
        DataException(
          'That learning item is not currently required of you.',
          cause: callableError(
            'failed-precondition',
            'That learning item is not currently required of you.',
          ),
        ),
      );
      expect(mapped, isA<ServerUpdateRequiredException>());
      expect(mapped, isNot(isA<PermissionDeniedException>()));
      expect(mapped.message, contains('server needs the latest update'));
      expect(mapped.message, contains('isn\'t a problem with your account'));
    });

    test('any other failure is passed through unchanged', () {
      final error = DataException(
        'That record no longer exists.',
        cause: callableError('not-found', 'That learning item is not available.'),
      );
      expect(WorkerLearningService.quizLoadError(error), same(error));
      const plain = DataException('Something went wrong.');
      expect(WorkerLearningService.quizLoadError(plain), same(plain));
    });
  });
}
