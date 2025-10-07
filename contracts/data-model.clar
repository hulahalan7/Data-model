(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-UNAUTHORIZED (err u102))
(define-constant ERR-INVALID-DATA (err u103))
(define-constant ERR-ALREADY-EXISTS (err u104))
(define-constant ERR-SCHEMA-MISMATCH (err u105))
(define-constant ERR-ACCESS-DENIED (err u106))
(define-constant ERR-INVALID-SCHEMA (err u107))
(define-constant ERR-VERSION-CONFLICT (err u108))
(define-constant ERR-RECORD-LOCKED (err u109))

(define-data-var next-schema-id uint u0)
(define-data-var next-record-id uint u0)
(define-data-var next-version-id uint u0)
(define-data-var validation-fee uint u1000)
(define-data-var storage-fee-per-kb uint u500)

(define-map data-schemas
    { schema-id: uint }
    {
        creator: principal,
        name: (string-ascii 100),
        description: (string-ascii 500),
        schema-definition: (string-ascii 2000),
        version: uint,
        is-active: bool,
        created-at: uint,
        record-count: uint,
        access-level: (string-ascii 20)
    }
)

(define-map data-records
    { record-id: uint }
    {
        schema-id: uint,
        owner: principal,
        data-hash: (buff 32),
        data-content: (string-ascii 2000),
        version: uint,
        created-at: uint,
        updated-at: uint,
        is-validated: bool,
        is-locked: bool,
        access-permissions: (string-ascii 50)
    }
)

(define-map schema-versions
    { version-id: uint }
    {
        schema-id: uint,
        version-number: uint,
        changes: (string-ascii 500),
        created-by: principal,
        created-at: uint,
        is-backwards-compatible: bool
    }
)

(define-map access-permissions
    { schema-id: uint, user: principal }
    {
        can-read: bool,
        can-write: bool,
        can-validate: bool,
        can-admin: bool,
        granted-by: principal,
        granted-at: uint
    }
)

(define-map data-validators
    { validator: principal }
    {
        reputation: uint,
        validations-performed: uint,
        successful-validations: uint,
        schemas-validated: uint,
        is-active: bool
    }
)

(define-map record-validations
    { record-id: uint, validator: principal }
    {
        is-valid: bool,
        validation-notes: (string-ascii 200),
        validated-at: uint,
        validation-score: uint
    }
)

(define-map schema-categories
    { category: (string-ascii 50) }
    { schema-count: uint, is-active: bool }
)

(define-private (get-schema-or-fail (schema-id uint))
    (ok (unwrap! (map-get? data-schemas { schema-id: schema-id }) ERR-NOT-FOUND))
)

(define-private (get-record-or-fail (record-id uint))
    (ok (unwrap! (map-get? data-records { record-id: record-id }) ERR-NOT-FOUND))
)

(define-private (has-schema-access (schema-id uint) (user principal) (permission (string-ascii 10)))
    (let ((access (map-get? access-permissions { schema-id: schema-id, user: user })))
        (if (is-some access)
            (let ((perms (unwrap-panic access)))
                (if (is-eq permission "read")
                    (get can-read perms)
                    (if (is-eq permission "write")
                        (get can-write perms)
                        (if (is-eq permission "validate")
                            (get can-validate perms)
                            (if (is-eq permission "admin")
                                (get can-admin perms)
                                false
                            )
                        )
                    )
                )
            )
            false
        )
    )
)

(define-private (calculate-storage-fee (data-size uint))
    (/ (* data-size (var-get storage-fee-per-kb)) u1024)
)

(define-private (update-validator-stats (validator principal) (success bool))
    (let ((stats (default-to
            { reputation: u0, validations-performed: u0, successful-validations: u0, schemas-validated: u0, is-active: true }
            (map-get? data-validators { validator: validator })
        )))
        (map-set data-validators
            { validator: validator }
            (merge stats {
                validations-performed: (+ (get validations-performed stats) u1),
                successful-validations: (if success (+ (get successful-validations stats) u1) (get successful-validations stats)),
                reputation: (if success (+ (get reputation stats) u10) (get reputation stats))
            })
        )
    )
)

(define-private (validate-data-format (data (string-ascii 2000)) (schema-def (string-ascii 2000)))
    (> (len data) u0)
)

(define-public (create-schema (name (string-ascii 100)) (description (string-ascii 500)) (schema-definition (string-ascii 2000)) (access-level (string-ascii 20)))
    (let ((schema-id (var-get next-schema-id)))
        (asserts! (> (len schema-definition) u0) ERR-INVALID-SCHEMA)
        (var-set next-schema-id (+ schema-id u1))
        (map-set data-schemas
            { schema-id: schema-id }
            {
                creator: tx-sender,
                name: name,
                description: description,
                schema-definition: schema-definition,
                version: u1,
                is-active: true,
                created-at: stacks-block-height,
                record-count: u0,
                access-level: access-level
            }
        )
        (map-set access-permissions
            { schema-id: schema-id, user: tx-sender }
            {
                can-read: true,
                can-write: true,
                can-validate: true,
                can-admin: true,
                granted-by: tx-sender,
                granted-at: stacks-block-height
            }
        )
        (ok schema-id)
    )
)

(define-public (create-record (schema-id uint) (data-content (string-ascii 2000)) (data-hash (buff 32)) (record-permissions (string-ascii 50)))
    (let (
        (schema (try! (get-schema-or-fail schema-id)))
        (record-id (var-get next-record-id))
        (storage-fee (calculate-storage-fee (len data-content)))
    )
        (asserts! (get is-active schema) ERR-INVALID-SCHEMA)
        (asserts! (or (is-eq tx-sender (get creator schema)) (has-schema-access schema-id tx-sender "write")) ERR-ACCESS-DENIED)
        (asserts! (validate-data-format data-content (get schema-definition schema)) ERR-INVALID-DATA)
        (try! (stx-transfer? storage-fee tx-sender CONTRACT-OWNER))
        (var-set next-record-id (+ record-id u1))
        (map-set data-records
            { record-id: record-id }
            {
                schema-id: schema-id,
                owner: tx-sender,
                data-hash: data-hash,
                data-content: data-content,
                version: u1,
                created-at: stacks-block-height,
                updated-at: stacks-block-height,
                is-validated: false,
                is-locked: false,
                access-permissions: record-permissions
            }
        )
        (map-set data-schemas
            { schema-id: schema-id }
            (merge schema { record-count: (+ (get record-count schema) u1) })
        )
        (ok record-id)
    )
)

(define-public (update-record (record-id uint) (new-data-content (string-ascii 2000)) (new-data-hash (buff 32)))
    (let ((record (try! (get-record-or-fail record-id))))
        (asserts! (is-eq tx-sender (get owner record)) ERR-UNAUTHORIZED)
        (asserts! (not (get is-locked record)) ERR-RECORD-LOCKED)
        (let (
            (schema (try! (get-schema-or-fail (get schema-id record))))
            (storage-fee (calculate-storage-fee (len new-data-content)))
        )
            (asserts! (validate-data-format new-data-content (get schema-definition schema)) ERR-INVALID-DATA)
            (try! (stx-transfer? storage-fee tx-sender CONTRACT-OWNER))
            (map-set data-records
                { record-id: record-id }
                (merge record {
                    data-content: new-data-content,
                    data-hash: new-data-hash,
                    version: (+ (get version record) u1),
                    updated-at: stacks-block-height,
                    is-validated: false
                })
            )
            (ok true)
        )
    )
)

(define-public (validate-record (record-id uint) (is-valid bool) (validation-notes (string-ascii 200)) (validation-score uint))
    (let ((record (try! (get-record-or-fail record-id))))
        (asserts! (or 
            (has-schema-access (get schema-id record) tx-sender "validate")
            (default-to false (get is-active (map-get? data-validators { validator: tx-sender })))
        ) ERR-ACCESS-DENIED)
        (try! (stx-transfer? (var-get validation-fee) tx-sender CONTRACT-OWNER))
        (map-set record-validations
            { record-id: record-id, validator: tx-sender }
            {
                is-valid: is-valid,
                validation-notes: validation-notes,
                validated-at: stacks-block-height,
                validation-score: validation-score
            }
        )
        (if is-valid
            (map-set data-records
                { record-id: record-id }
                (merge record { is-validated: true })
            )
            true
        )
        (update-validator-stats tx-sender is-valid)
        (ok true)
    )
)

(define-public (grant-access (schema-id uint) (user principal) (can-read bool) (can-write bool) (can-validate bool) (can-admin bool))
    (let ((schema (try! (get-schema-or-fail schema-id))))
        (asserts! (or 
            (is-eq tx-sender (get creator schema))
            (has-schema-access schema-id tx-sender "admin")
        ) ERR-UNAUTHORIZED)
        (map-set access-permissions
            { schema-id: schema-id, user: user }
            {
                can-read: can-read,
                can-write: can-write,
                can-validate: can-validate,
                can-admin: can-admin,
                granted-by: tx-sender,
                granted-at: stacks-block-height
            }
        )
        (ok true)
    )
)

(define-public (create-schema-version (schema-id uint) (changes (string-ascii 500)) (is-backwards-compatible bool))
    (let (
        (schema (try! (get-schema-or-fail schema-id)))
        (version-id (var-get next-version-id))
    )
        (asserts! (or 
            (is-eq tx-sender (get creator schema))
            (has-schema-access schema-id tx-sender "admin")
        ) ERR-UNAUTHORIZED)
        (var-set next-version-id (+ version-id u1))
        (map-set schema-versions
            { version-id: version-id }
            {
                schema-id: schema-id,
                version-number: (+ (get version schema) u1),
                changes: changes,
                created-by: tx-sender,
                created-at: stacks-block-height,
                is-backwards-compatible: is-backwards-compatible
            }
        )
        (map-set data-schemas
            { schema-id: schema-id }
            (merge schema { version: (+ (get version schema) u1) })
        )
        (ok version-id)
    )
)

(define-public (register-validator)
    (begin
        (map-set data-validators
            { validator: tx-sender }
            {
                reputation: u0,
                validations-performed: u0,
                successful-validations: u0,
                schemas-validated: u0,
                is-active: true
            }
        )
        (ok true)
    )
)

(define-public (lock-record (record-id uint))
    (let ((record (try! (get-record-or-fail record-id))))
        (asserts! (is-eq tx-sender (get owner record)) ERR-UNAUTHORIZED)
        (map-set data-records
            { record-id: record-id }
            (merge record { is-locked: true })
        )
        (ok true)
    )
)

(define-public (update-platform-settings (validation-fee-new uint) (storage-fee-new uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (var-set validation-fee validation-fee-new)
        (var-set storage-fee-per-kb storage-fee-new)
        (ok true)
    )
)

(define-read-only (get-schema (schema-id uint))
    (map-get? data-schemas { schema-id: schema-id })
)

(define-read-only (get-record (record-id uint))
    (map-get? data-records { record-id: record-id })
)

(define-read-only (get-schema-version (version-id uint))
    (map-get? schema-versions { version-id: version-id })
)

(define-read-only (get-access-permissions (schema-id uint) (user principal))
    (map-get? access-permissions { schema-id: schema-id, user: user })
)

(define-read-only (get-validator-stats (validator principal))
    (map-get? data-validators { validator: validator })
)

(define-read-only (get-record-validation (record-id uint) (validator principal))
    (map-get? record-validations { record-id: record-id, validator: validator })
)

(define-read-only (get-platform-stats)
    {
        total-schemas: (var-get next-schema-id),
        total-records: (var-get next-record-id),
        total-versions: (var-get next-version-id),
        validation-fee: (var-get validation-fee),
        storage-fee-per-kb: (var-get storage-fee-per-kb)
    }
)

(define-read-only (can-access-schema (schema-id uint) (user principal) (permission (string-ascii 10)))
    (has-schema-access schema-id user permission)
)