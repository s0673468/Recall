import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPaths = <String>[
    'scripts/supabase/migrations/000_base_schema.sql',
    'scripts/supabase/migrations/001_note_flags.sql',
    'scripts/supabase/migrations/002_cards_suspended.sql',
    'scripts/supabase/migrations/003_concept_nodes.sql',
    'scripts/supabase/migrations/004_concept_pages.sql',
    'scripts/supabase/migrations/005_review_event_idempotency.sql',
    'scripts/supabase/migrations/006_apply_review_rpc.sql',
  ];

  const tableContracts = <String>{
    'decks',
    'notes',
    'cards',
    'review_log',
    'user_settings',
    'note_flags',
    'concept_nodes',
    'concept_pages',
  };

  test('every client Supabase object has an ordered canonical migration', () {
    final api = File(
      'lib/features/review/data/recall_api.dart',
    ).readAsStringSync();
    final clientTables = RegExp(
      r"\.from\('([a-z_]+)'\)",
    ).allMatches(api).map((match) => match.group(1)!).toSet();
    final clientRpcs = RegExp(
      r"\.rpc(?:<[^>]+>)?\(\s*'([a-z_]+)'",
    ).allMatches(api).map((match) => match.group(1)!).toSet();

    expect(clientTables, tableContracts);
    expect(clientRpcs, {'apply_review', 'deck_counts'});

    final migrations = migrationPaths
        .map((path) {
          final file = File(path);
          expect(file.existsSync(), isTrue, reason: '$path must be checked in');
          final sql = file.readAsStringSync().toLowerCase();
          expect(
            sql,
            contains('begin;'),
            reason: '$path must apply atomically',
          );
          expect(
            sql,
            contains('commit;'),
            reason: '$path must apply atomically',
          );
          return sql;
        })
        .join('\n');

    for (final table in tableContracts) {
      expect(
        migrations,
        contains('public.$table'),
        reason: '$table needs repository-owned DDL',
      );
    }
    for (final rpc in clientRpcs) {
      expect(
        migrations,
        contains('function public.$rpc'),
        reason: '$rpc needs repository-owned DDL',
      );
    }
  });

  test('schema sources cover importer, flag, and concept sync fields', () {
    final migrations = migrationPaths
        .map((path) => File(path).readAsStringSync().toLowerCase())
        .join('\n');
    final verifier = File(
      'scripts/supabase/verify/verify_schema.sql',
    ).readAsStringSync().toLowerCase();

    const requiredColumns = <String>{
      'front',
      'back',
      'tags',
      'has_latex',
      'latex_svg',
      'anki_mod',
      'stability',
      'difficulty',
      'due',
      'state',
      'reps',
      'lapses',
      'last_review',
      'cloud_seen',
      'suspended',
      'client_event_id',
      'status',
      'resolved_at',
      'resolution',
      'module',
      'body_html',
      'figure_svg',
      'settings_value',
    };
    for (final column in requiredColumns) {
      expect(migrations, contains(column), reason: 'missing DDL for $column');
      expect(
        verifier,
        contains("'$column'"),
        reason: 'missing verify for $column',
      );
    }

    expect(
      migrations,
      contains("'wrong', 'confusing', 'too_long', 'duplicate'"),
    );
    expect(migrations, contains("'open', 'resolved', 'dismissed'"));
    expect(migrations, contains('on conflict (card_id, client_event_id)'));
    expect(migrations, contains('security invoker'));
    expect(migrations, contains('c.suspended = false'));
  });

  test('verification and non-destructive rollback files are present', () {
    const paths = <String>[
      'scripts/supabase/verify/verify_schema.sql',
      'scripts/supabase/verify/verify_apply_review.sql',
      'scripts/supabase/rollback/006_drop_apply_review_rpc.sql',
      'scripts/supabase/rollback/005_drop_event_unique_indexes.sql',
    ];
    for (final path in paths) {
      expect(File(path).existsSync(), isTrue, reason: '$path must exist');
    }

    final rollback = File(
      'scripts/supabase/rollback/005_drop_event_unique_indexes.sql',
    ).readAsStringSync().toLowerCase();
    expect(rollback, isNot(contains('drop column')));
    expect(rollback, contains('drop index if exists'));
  });

  test('setup docs point to the repository-owned schema guide', () {
    final schemaGuide = File('scripts/supabase/README.md').readAsStringSync();
    final readme = File('README.md').readAsStringSync();
    final iosSetup = File('IOS_SETUP.md').readAsStringSync();
    final flagDocs = File('tools/flag_report/README.md').readAsStringSync();

    for (final path in migrationPaths) {
      final relative = path.replaceFirst('scripts/supabase/', '');
      expect(schemaGuide, contains(relative));
    }
    for (final docs in [readme, iosSetup, flagDocs]) {
      expect(docs, contains('scripts/supabase/'));
    }
    expect(
      readme,
      isNot(contains('scripts/supabase_migrate_recall_review_rpc.sql')),
    );
    expect(
      iosSetup,
      isNot(contains('scripts/supabase_migrate_recall_idempotency.sql')),
    );
    expect(flagDocs, isNot(contains('has no versioned Supabase DDL')));
  });

  test('schema sources contain no project or credential identifiers', () {
    final schemaFiles = Directory(
      'scripts/supabase',
    ).listSync(recursive: true).whereType<File>();
    for (final file in schemaFiles) {
      final contents = file.readAsStringSync();
      expect(
        contents,
        isNot(contains('evqukpdqecxcmdvvehmy')),
        reason: '${file.path} must stay project-agnostic',
      );
    }
  });
}
