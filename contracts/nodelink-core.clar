;; nodelink-core
;; This smart contract serves as the backbone of the NodeLink P2P network, enabling decentralized file sharing
;; by managing node registration, file metadata storage, and access permissions on the Stacks blockchain.
;; The contract maintains registries for network nodes and shared files, implements an access control system,
;; and tracks node reputation to incentivize reliable participation in the network.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NODE-ALREADY-REGISTERED (err u101))
(define-constant ERR-NODE-NOT-FOUND (err u102))
(define-constant ERR-FILE-ALREADY-REGISTERED (err u103))
(define-constant ERR-FILE-NOT-FOUND (err u104))
(define-constant ERR-INVALID-REPUTATION-UPDATE (err u105))
(define-constant ERR-INVALID-PARAMS (err u106))
(define-constant ERR-NO-ACCESS-PERMISSION (err u107))
(define-constant ERR-CANNOT-REVOKE-OWNER (err u108))

;; Data space definitions

;; Node structure: stores information about network participants
(define-map nodes
  { node-address: principal }
  {
    network-id: (string-utf8 50),      ;; Network identifier for P2P connections
    public-key: (buff 33),             ;; Public key for secure communications
    metadata: (optional (string-utf8 255)),  ;; Optional node metadata (e.g., node type, region)
    reputation: uint,                  ;; Node reputation score
    registration-time: uint,           ;; Block height when node was registered
    last-active: uint                  ;; Block height of last activity
  }
)

;; File metadata structure: stores information about shared files
(define-map files
  { file-id: (string-utf8 50) }
  {
    owner: principal,                  ;; File owner's principal
    content-hash: (buff 32),           ;; SHA-256 hash of the file content (for integrity verification)
    description: (string-utf8 255),    ;; File description
    size-bytes: uint,                  ;; File size in bytes
    creation-time: uint,               ;; Block height when file was registered
    times-accessed: uint               ;; Number of times the file has been accessed
  }
)

;; Access permissions: controls who can access which files
(define-map file-permissions
  { file-id: (string-utf8 50), user: principal }
  {
    can-access: bool,                  ;; Whether user can access the file
    granted-by: principal,             ;; Who granted the permission
    granted-at: uint                   ;; Block height when permission was granted
  }
)

;; File hosting nodes: tracks which nodes are hosting which files
(define-map file-hosts
  { file-id: (string-utf8 50), node-address: principal }
  {
    added-at: uint,                    ;; Block height when node started hosting
    last-verified: uint                ;; Block height when availability was last verified
  }
)

;; Private functions

;; Check if caller is registered as a node
(define-private (is-registered-node (caller principal))
  (default-to false (map-get? nodes { node-address: caller }))
)

;; Check if caller owns the specified file
(define-private (is-file-owner (file-id (string-utf8 50)) (caller principal))
  (let ((file-info (map-get? files { file-id: file-id })))
    (and 
      (is-some file-info)
      (is-eq caller (get owner (unwrap-panic file-info)))
    )
  )
)

;; Check if user has access permission for a file
(define-private (has-file-access (file-id (string-utf8 50)) (user principal))
  (let ((file-info (map-get? files { file-id: file-id }))
        (permission (map-get? file-permissions { file-id: file-id, user: user })))
    (or
      ;; User is the file owner
      (and 
        (is-some file-info)
        (is-eq user (get owner (unwrap-panic file-info)))
      )
      ;; User has been granted explicit permission
      (and
        (is-some permission)
        (get can-access (unwrap-panic permission))
      )
    )
  )
)

;; Update node's last active timestamp
(define-private (update-last-active (node-address principal))
  (let ((node-info (map-get? nodes { node-address: node-address })))
    (if (is-some node-info)
      (map-set nodes
        { node-address: node-address }
        (merge (unwrap-panic node-info) { last-active: block-height })
      )
      false
    )
  )
)

;; Increment file access counter
(define-private (increment-file-access (file-id (string-utf8 50)))
  (let ((file-info (map-get? files { file-id: file-id })))
    (if (is-some file-info)
      (let ((current-info (unwrap-panic file-info)))
        (map-set files
          { file-id: file-id }
          (merge current-info { times-accessed: (+ (get times-accessed current-info) u1) })
        )
      )
      false
    )
  )
)

;; Read-only functions

;; Get node information
(define-read-only (get-node-info (node-address principal))
  (let ((node-info (map-get? nodes { node-address: node-address })))
    (if (is-some node-info)
      (ok (unwrap-panic node-info))
      ERR-NODE-NOT-FOUND
    )
  )
)

;; Get file information
(define-read-only (get-file-info (file-id (string-utf8 50)))
  (let ((file-info (map-get? files { file-id: file-id })))
    (if (is-some file-info)
      (ok (unwrap-panic file-info))
      ERR-FILE-NOT-FOUND
    )
  )
)

;; Check if a user has permission to access a file
(define-read-only (check-file-access (file-id (string-utf8 50)) (user principal))
  (if (has-file-access file-id user)
    (ok true)
    (err false)
  )
)

;; Get nodes hosting a specific file
(define-read-only (get-file-hosting-nodes (file-id (string-utf8 50)))
  (let ((file-info (map-get? files { file-id: file-id })))
    (if (is-none file-info)
      ERR-FILE-NOT-FOUND
      (ok file-id) ;; In a real implementation, we would return the list of nodes hosting this file
                   ;; This requires iterating over file-hosts map which isn't directly supported in Clarity
    )
  )
)

;; Public functions

;; Register a new node
(define-public (register-node 
  (network-id (string-utf8 50))
  (public-key (buff 33))
  (metadata (optional (string-utf8 255))))
  
  (let ((node-exists (map-get? nodes { node-address: tx-sender })))
    (if (is-some node-exists)
      ERR-NODE-ALREADY-REGISTERED
      (begin
        (map-set nodes
          { node-address: tx-sender }
          {
            network-id: network-id,
            public-key: public-key,
            metadata: metadata,
            reputation: u100, ;; Initial reputation score
            registration-time: block-height,
            last-active: block-height
          }
        )
        (ok true)
      )
    )
  )
)

;; Update node information
(define-public (update-node-info
  (network-id (string-utf8 50))
  (public-key (buff 33))
  (metadata (optional (string-utf8 255))))
  
  (let ((node-info (map-get? nodes { node-address: tx-sender })))
    (if (is-none node-info)
      ERR-NODE-NOT-FOUND
      (begin
        (map-set nodes
          { node-address: tx-sender }
          (merge (unwrap-panic node-info)
            {
              network-id: network-id,
              public-key: public-key,
              metadata: metadata,
              last-active: block-height
            }
          )
        )
        (ok true)
      )
    )
  )
)

;; Register a new file
(define-public (register-file
  (file-id (string-utf8 50))
  (content-hash (buff 32))
  (description (string-utf8 255))
  (size-bytes uint))
  
  (let ((file-exists (map-get? files { file-id: file-id })))
    (if (is-some file-exists)
      ERR-FILE-ALREADY-REGISTERED
      (begin
        ;; Check that caller is a registered node
        (if (is-registered-node tx-sender)
          (begin
            ;; Register file metadata
            (map-set files
              { file-id: file-id }
              {
                owner: tx-sender,
                content-hash: content-hash,
                description: description,
                size-bytes: size-bytes,
                creation-time: block-height,
                times-accessed: u0
              }
            )
            
            ;; Add self as initial host
            (map-set file-hosts
              { file-id: file-id, node-address: tx-sender }
              {
                added-at: block-height,
                last-verified: block-height
              }
            )
            
            ;; Update node's last active timestamp
            (update-last-active tx-sender)
            (ok true)
          )
          ERR-NODE-NOT-FOUND
        )
      )
    )
  )
)

;; Update file metadata
(define-public (update-file-metadata
  (file-id (string-utf8 50))
  (description (string-utf8 255)))
  
  (let ((file-info (map-get? files { file-id: file-id })))
    (if (is-none file-info)
      ERR-FILE-NOT-FOUND
      (if (is-file-owner file-id tx-sender)
        (begin
          (map-set files
            { file-id: file-id }
            (merge (unwrap-panic file-info) { description: description })
          )
          (update-last-active tx-sender)
          (ok true)
        )
        ERR-NOT-AUTHORIZED
      )
    )
  )
)

;; Grant file access permission to a user
(define-public (grant-file-access (file-id (string-utf8 50)) (user principal))
  (let ((file-info (map-get? files { file-id: file-id })))
    (if (is-none file-info)
      ERR-FILE-NOT-FOUND
      (if (is-file-owner file-id tx-sender)
        (begin
          (map-set file-permissions
            { file-id: file-id, user: user }
            {
              can-access: true,
              granted-by: tx-sender,
              granted-at: block-height
            }
          )
          (update-last-active tx-sender)
          (ok true)
        )
        ERR-NOT-AUTHORIZED
      )
    )
  )
)

;; Revoke file access permission from a user
(define-public (revoke-file-access (file-id (string-utf8 50)) (user principal))
  (let ((file-info (map-get? files { file-id: file-id })))
    (if (is-none file-info)
      ERR-FILE-NOT-FOUND
      (if (is-file-owner file-id tx-sender)
        (if (is-eq user (get owner (unwrap-panic file-info)))
          ERR-CANNOT-REVOKE-OWNER
          (begin
            (map-set file-permissions
              { file-id: file-id, user: user }
              {
                can-access: false,
                granted-by: tx-sender,
                granted-at: block-height
              }
            )
            (update-last-active tx-sender)
            (ok true)
          )
        )
        ERR-NOT-AUTHORIZED
      )
    )
  )
)

;; Register as a host for a file
(define-public (host-file (file-id (string-utf8 50)))
  (let ((file-info (map-get? files { file-id: file-id }))
        (node-info (map-get? nodes { node-address: tx-sender })))
    (if (is-none file-info)
      ERR-FILE-NOT-FOUND
      (if (is-none node-info)
        ERR-NODE-NOT-FOUND
        (if (has-file-access file-id tx-sender)
          (begin
            (map-set file-hosts
              { file-id: file-id, node-address: tx-sender }
              {
                added-at: block-height,
                last-verified: block-height
              }
            )
            (update-last-active tx-sender)
            (ok true)
          )
          ERR-NO-ACCESS-PERMISSION
        )
      )
    )
  )
)

;; Record file access (called when a user successfully accesses a file)
(define-public (record-file-access (file-id (string-utf8 50)) (accessor principal))
  (let ((file-info (map-get? files { file-id: file-id })))
    (if (is-none file-info)
      ERR-FILE-NOT-FOUND
      (if (has-file-access file-id accessor)
        (begin
          (increment-file-access file-id)
          (update-last-active tx-sender)
          (ok true)
        )
        ERR-NO-ACCESS-PERMISSION
      )
    )
  )
)

;; Update node reputation (can only be called by contract owner or other authorized mechanisms)
;; In a production implementation, this would likely use a more sophisticated approach with proper governance
(define-public (update-node-reputation (node-address principal) (points-change int))
  (let ((node-info (map-get? nodes { node-address: node-address })))
    (if (is-none node-info)
      ERR-NODE-NOT-FOUND
      (if (is-eq tx-sender (unwrap-panic (contract-call? 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM.nodelink-governance get-admin)))
        (let ((current-info (unwrap-panic node-info))
              (current-rep (get reputation current-info))
              (new-rep (if (< points-change 0)
                          (if (> (abs points-change) current-rep)
                            u0
                            (- current-rep (abs points-change))
                          )
                          (+ current-rep (abs points-change))
                        )))
          (map-set nodes
            { node-address: node-address }
            (merge current-info { reputation: new-rep })
          )
          (ok true)
        )
        ERR-NOT-AUTHORIZED
      )
    )
  )
)

;; Ping to update node's last active timestamp (for maintaining uptime records)
(define-public (ping)
  (let ((node-info (map-get? nodes { node-address: tx-sender })))
    (if (is-none node-info)
      ERR-NODE-NOT-FOUND
      (begin
        (update-last-active tx-sender)
        (ok true)
      )
    )
  )
)