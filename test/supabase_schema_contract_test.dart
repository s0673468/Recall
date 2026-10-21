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
    'scripts/supabase/migrations/007_note_flags_hide_reasons.sql',
    'scripts/supabase/migrations/008_apply_review_missing_card.sql',
    'scripts/supabase/migrations/009_concept_pages_extra_figures.sql',
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
      'extra_figures',
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
    expect(migrations, contains("'dislike', 'delete'"));
    expect(migrations, contains('on conflict (card_id, client_event_id)'));
    expect(migrations, contains('security invoker'));
    expect(migrations, contains('c.suspended = false'));
  });

  test('the newest apply_review acknowledges a hard-deleted card', () {
    final rpcMigrations = migrationPaths
        .where(
          (path) => File(
            path,
          ).readAsStringSync().contains('function public.apply_review('),
        )
        .toList();
    expect(rpcMigrations.last, endsWith('008_apply_review_missing_card.sql'));
    final sql = File(rpcMigrations.last).readAsStringSync().toLowerCase();
    // The card is read before any log insert, and only the review_log ->
    // cards foreign key turns into a 0 acknowledgement without a log row.
    expect(
      sql.indexOf('from public.cards'),
      lessThan(sql.indexOf('insert into public.review_log')),
    );
    expect(sql, contains('exception when foreign_key_violation'));
    expect(sql, contains("confrelid = 'public.cards'::regclass"));
    expect(sql, contains('return 0;'));
    expect(sql, contains('\nsecurity invoker\n'));
    expect(sql, contains('set search_path = public, pg_temp'));
    expect(sql, contains('on conflict (card_id, client_event_id) do nothing'));
    expect(
      sql,
      contains("raise exception 'apply_review requires a client_event_id'"),
    );
    expect(sql, contains(') to authenticated;'));

    final verifier = File(
      'scripts/supabase/verify/verify_apply_review.sql',
    ).readAsStringSync();
    expect(verifier, contains('E:fk_blocks_outbox'));
    expect(
      File('scripts/supabase/verify/verify_schema.sql').readAsStringSync(),
      contains('apply_review predates 008'),
    );
    expect(
      File('scripts/supabase/tests/test_apply_review_pg.py').existsSync(),
      isTrue,
    );
  });

  test('extra_figures is additive and bounded to an array of three', () {
    final sql = File(
      'scripts/supabase/migrations/009_concept_pages_extra_figures.sql',
    ).readAsStringSync().toLowerCase();
    expect(
      sql,
      contains(
        'add column if not exists extra_figures jsonb not null '
        "default '[]'::jsonb",
      ),
    );
    expect(sql, contains("jsonb_typeof(extra_figures) = 'array'"));
    expect(sql, contains('jsonb_array_length(extra_figures) <= 3'));
    expect(sql, isNot(contains('drop column')));
    expect(sql, isNot(contains('grant ')));
    expect(sql, isNot(contains('policy')));

    final api = File(
      'lib/features/review/data/recall_api.dart',
    ).readAsStringSync();
    expect(
      api,
      contains("'node_id,title,body_html,figure_svg,extra_figures,updated_at'"),
    );
    expect(
      File('scripts/supabase/verify/verify_schema.sql').readAsStringSync(),
      contains('concept_pages_extra_figures_check'),
    );
  });

  test('verification and non-destructive rollback files are present', () {
    const paths = <String>[
      'scripts/supabase/verify/verify_schema.sql',
      'scripts/supabase/verify/verify_apply_review.sql',
      'scripts/supabase/rollback/006_drop_apply_review_rpc.sql',
      'scripts/supabase/rollback/005_drop_event_unique_indexes.sql',
      'scripts/supabase/rollback/007_restore_flag_reasons.sql',
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

  test('historical iOS setup points to the repository-owned schema guide', () {
    final iosSetup = File('IOS_SETUP.md').readAsStringSync();
    expect(iosSetup, contains('scripts/supabase/'));
    expect(
      iosSetup,
      isNot(contains('scripts/supabase_migrate_recall_idempotency.sql')),
    );
  }, tags: const ['apple-mobile']);

  test('setup docs point to the repository-owned schema guide', () {
    final schemaGuide = File('scripts/supabase/README.md').readAsStringSync();
    final readme = File('README.md').readAsStringSync();
    final flagDocs = File('tools/flag_report/README.md').readAsStringSync();

    for (final path in migrationPaths) {
      final relative = path.replaceFirst('scripts/supabase/', '');
      expect(schemaGuide, contains(relative));
    }
    for (final docs in [readme, flagDocs]) {
      expect(docs, contains('scripts/supabase/'));
    }
    expect(
      readme,
      isNot(contains('scripts/supabase_migrate_recall_review_rpc.sql')),
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
