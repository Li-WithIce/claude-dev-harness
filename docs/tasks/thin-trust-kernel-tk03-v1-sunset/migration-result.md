# Authorized paused migration

Executed on baseline `2e1949d7bcedc5397404d86a5ce95b51c8dde4a0`, under
TK-03 task version 3 and current user Approval
`apr_tk03_authorized_paused_migration_v3`.

- Protected operation: `sha256:bbba7133e0a3ee3590c2f29987b37d6ae199a67b4086b49d5f87ad12a540e105`.
- Old v1 pointer: CAS-released from
  `sha256:00266b819dccb93ca81bb59dfa17095e89a4f4d54db2cefeff914fea41b6b041`
  to canonical idle bytes
  `sha256:35d6fde1f61b43ebec9b95eda3be0e43437b73f3d56fb22d8746a24ab98eb167`.
- Independent preview: `/root/tk03_migration_review`, UTC
  2026-08-31T09:29:49.4090352Z through 09:29:50.5259779Z, exit 0, no writes.
- Independent native live dry-run: same non-implementing actor/context, UTC
  2026-08-31T09:30:42.2510821Z through 09:30:44.7356772Z, exit 0,
  v1_writes=0 and v2_writes=0. Exact model identifier was not exposed.
- Native dry-run digest:
  `sha256:50dbfeff468938727913db1f1fb33f033e6252c68f7b5c27e0aaa1354b574c4c`.
- Formal migration: native `-ConfirmMigration -ExpectedDryRunDigest` with the
  preceding digest, exit 0. Imported `dp-03-real-qualification` is v2 `paused`,
  task version 1, not running or done.
- Imported Contract:
  `sha256:4b07bde288b91e402adb1a62a25883d14bf1cad76c6aea71a483373c4d03f172`.
- Qualification and other Release operations: `not_run`.

Postconditions were checked by the scoped driver immediately after publication:

| Preserved file | Before and after raw SHA-256 |
|---|---|
| Original plan | `6d3d07c4cb2621818fae16e3155915f8963d76580844e7e7f9505d6d1eb9b249` |
| Original test/Evidence | `349715eab4b6ecb4c4a101095a10644b683e0cfd275d0d6145fc9ecd34b8391f` |
| Original skill manifest | `4db68292c87b0549c01b7f9bdb7c852594e80b6f51525a67a9382ebffa00e5f9` |
| runtime-config-persistence DONE plan | `53d597fa437e9b877f81a9018a3e94d7ebe49106f1957873eae7adeb665bf28a` |
| thin-harness-v2-refactor DONE plan | `b3ec6115a0d6f27b0b0a362f05832479d66cb6e393e22efb7e51ba7fd96213bd` |
| Existing v2 current pointer | `f780c99a9a70ccf9286b10dd59e98b3bc270ecba0acb457d10841b434d09f3c8` |

Private preimage bytes, snapshot, Approval, native output and driver are retained
under `tmp/tk03-validation`. This report is migration evidence, not a complete
TK-03 audit, global workspace inventory, or physical-removal authorization.
