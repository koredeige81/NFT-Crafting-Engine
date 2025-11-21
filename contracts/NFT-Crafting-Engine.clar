
(define-non-fungible-token crafted-nft uint)

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-token-owner (err u101))
(define-constant err-invalid-recipe (err u102))
(define-constant err-event-not-active (err u103))
(define-constant err-insufficient-materials (err u104))
(define-constant err-token-not-found (err u105))
(define-constant err-recipe-not-found (err u106))
(define-constant err-cooldown-active (err u107))
(define-constant err-not-listed (err u108))
(define-constant err-already-listed (err u109))
(define-constant err-insufficient-payment (err u110))
(define-constant err-batch-limit-exceeded (err u111))
(define-constant max-batch-size u5)

(define-data-var last-token-id uint u0)
(define-data-var crafting-fee uint u1000000)
(define-data-var global-crafting-enabled bool true)

(define-map token-metadata uint {
    name: (string-ascii 64),
    rarity: uint,
    power-level: uint,
    crafted-at: uint,
    ingredients: (list 10 uint)
})

(define-map crafting-recipes uint {
    required-tokens: (list 5 uint),
    required-rarities: (list 5 uint),
    output-rarity: uint,
    output-power: uint,
    enabled: bool,
    min-tokens: uint
})

(define-map time-limited-events uint {
    recipe-id: uint,
    start-block: uint,
    end-block: uint,
    bonus-power: uint,
    active: bool
})

(define-map user-cooldowns principal uint)
(define-map token-burn-history uint {burner: principal, burned-at: uint})

(define-map marketplace-listings uint {
    seller: principal,
    price: uint,
    listed-at: uint
})

(define-map batch-craft-history principal {
    total-batches: uint,
    total-crafted: uint,
    last-batch-block: uint
})

(define-read-only (get-last-token-id)
    (var-get last-token-id)
)

(define-read-only (get-token-uri (token-id uint))
    (ok none)
)

(define-read-only (get-owner (token-id uint))
    (ok (nft-get-owner? crafted-nft token-id))
)

(define-read-only (get-token-metadata (token-id uint))
    (map-get? token-metadata token-id)
)

(define-read-only (get-crafting-recipe (recipe-id uint))
    (map-get? crafting-recipes recipe-id)
)

(define-read-only (get-time-limited-event (event-id uint))
    (map-get? time-limited-events event-id)
)

(define-read-only (get-user-cooldown (user principal))
    (default-to u0 (map-get? user-cooldowns user))
)

(define-read-only (is-crafting-allowed (user principal))
    (and 
        (var-get global-crafting-enabled)
        (< (get-user-cooldown user) stacks-block-height)
    )
)

(define-read-only (get-listing (token-id uint))
    (map-get? marketplace-listings token-id)
)

(define-read-only (is-listed (token-id uint))
    (is-some (map-get? marketplace-listings token-id))
)

(define-read-only (get-batch-craft-history (user principal))
    (default-to {total-batches: u0, total-crafted: u0, last-batch-block: u0} 
        (map-get? batch-craft-history user))
)

(define-read-only (calculate-crafting-power (recipe-id uint) (event-id (optional uint)))
    (let (
        (recipe (unwrap! (get-crafting-recipe recipe-id) u0))
        (base-power (get output-power recipe))
    )
        (match event-id
            some-event (let (
                (event-data (unwrap! (get-time-limited-event some-event) base-power))
            )
                (if (and 
                        (get active event-data)
                        (>= stacks-block-height (get start-block event-data))
                        (<= stacks-block-height (get end-block event-data))
                        (is-eq (get recipe-id event-data) recipe-id)
                    )
                    (+ base-power (get bonus-power event-data))
                    base-power
                )
            )
            base-power
        )
    )
)

(define-private (mint-crafted-nft (recipient principal) (name (string-ascii 64)) (rarity uint) (power uint) (ingredients (list 10 uint)))
    (let (
        (token-id (+ (var-get last-token-id) u1))
    )
        (try! (nft-mint? crafted-nft token-id recipient))
        (map-set token-metadata token-id {
            name: name,
            rarity: rarity,
            power-level: power,
            crafted-at: stacks-block-height,
            ingredients: ingredients
        })
        (var-set last-token-id token-id)
        (ok token-id)
    )
)

(define-private (burn-tokens (token-ids (list 10 uint)) (owner principal))
    (fold check-and-burn token-ids (ok true))
)

(define-private (check-and-burn (token-id uint) (prev-result (response bool uint)))
    (match prev-result
        ok-val (let (
            (token-owner (unwrap! (nft-get-owner? crafted-nft token-id) (err u105)))
        )
            (if (is-eq token-owner tx-sender)
                (match (nft-burn? crafted-nft token-id token-owner)
                    ok-burn (begin
                        (map-set token-burn-history token-id {burner: tx-sender, burned-at: stacks-block-height})
                        (ok true)
                    )
                    err-burn (err u105)
                )
                (err u101)
            )
        )
        err-val (err err-val)
    )
)

(define-private (validate-recipe-materials (token-ids (list 10 uint)) (recipe-id uint))
    (let (
        (recipe (unwrap! (get-crafting-recipe recipe-id) (err u106)))
        (required-rarities (get required-rarities recipe))
        (min-tokens (get min-tokens recipe))
    )
        (if (and 
                (get enabled recipe)
                (>= (len token-ids) min-tokens)
                (check-rarity-requirements token-ids required-rarities)
            )
            (ok true)
            (err u102)
        )
    )
)

(define-private (check-rarity-requirements (token-ids (list 10 uint)) (required-rarities (list 5 uint)))
    (fold check-single-rarity required-rarities true)
)

(define-private (check-single-rarity (required-rarity uint) (prev-result bool))
    (and prev-result (> required-rarity u0))
)

(define-public (craft-nft (token-ids (list 10 uint)) (recipe-id uint) (event-id (optional uint)) (output-name (string-ascii 64)))
    (let (
        (recipe (unwrap! (get-crafting-recipe recipe-id) err-recipe-not-found))
        (crafting-power (calculate-crafting-power recipe-id event-id))
        (current-block stacks-block-height)
    )
        (asserts! (is-crafting-allowed tx-sender) err-cooldown-active)
        (asserts! (var-get global-crafting-enabled) err-owner-only)
        (try! (validate-recipe-materials token-ids recipe-id))
        (try! (stx-transfer? (var-get crafting-fee) tx-sender contract-owner))
        (try! (burn-tokens token-ids tx-sender))
        (map-set user-cooldowns tx-sender (+ current-block u10))
        (mint-crafted-nft tx-sender output-name (get output-rarity recipe) crafting-power token-ids)
    )
)

(define-private (process-single-batch-craft (craft-data {token-ids: (list 10 uint), recipe-id: uint, output-name: (string-ascii 64)}) (prev-result (response (list 5 uint) uint)))
    (match prev-result
        ok-list (let (
            (recipe (unwrap! (get-crafting-recipe (get recipe-id craft-data)) (err u106)))
            (crafting-power (calculate-crafting-power (get recipe-id craft-data) none))
        )
            (try! (validate-recipe-materials (get token-ids craft-data) (get recipe-id craft-data)))
            (try! (burn-tokens (get token-ids craft-data) tx-sender))
            (let (
                (new-token-id (unwrap! (mint-crafted-nft tx-sender (get output-name craft-data) (get output-rarity recipe) crafting-power (get token-ids craft-data)) (err u105)))
            )
                (ok (unwrap! (as-max-len? (append ok-list new-token-id) u5) (err u111)))
            )
        )
        err-val (err err-val)
    )
)

(define-public (batch-craft-nft (crafts (list 5 {token-ids: (list 10 uint), recipe-id: uint, output-name: (string-ascii 64)})))
    (let (
        (batch-count (len crafts))
        (total-fee (* (var-get crafting-fee) batch-count))
        (current-block stacks-block-height)
        (history (get-batch-craft-history tx-sender))
    )
        (asserts! (is-crafting-allowed tx-sender) err-cooldown-active)
        (asserts! (var-get global-crafting-enabled) err-owner-only)
        (asserts! (<= batch-count max-batch-size) err-batch-limit-exceeded)
        (asserts! (> batch-count u0) err-invalid-recipe)
        (try! (stx-transfer? total-fee tx-sender contract-owner))
        (let (
            (result (fold process-single-batch-craft crafts (ok (list))))
        )
            (map-set user-cooldowns tx-sender (+ current-block u10))
            (map-set batch-craft-history tx-sender {
                total-batches: (+ (get total-batches history) u1),
                total-crafted: (+ (get total-crafted history) batch-count),
                last-batch-block: current-block
            })
            result
        )
    )
)

(define-public (transfer (token-id uint) (sender principal) (recipient principal))
    (begin
        (asserts! (is-eq tx-sender sender) err-not-token-owner)
        (nft-transfer? crafted-nft token-id sender recipient)
    )
)

(define-public (add-crafting-recipe (recipe-id uint) (required-tokens (list 5 uint)) (required-rarities (list 5 uint)) (output-rarity uint) (output-power uint) (min-tokens uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (map-set crafting-recipes recipe-id {
            required-tokens: required-tokens,
            required-rarities: required-rarities,
            output-rarity: output-rarity,
            output-power: output-power,
            enabled: true,
            min-tokens: min-tokens
        }))
    )
)

(define-public (toggle-recipe (recipe-id uint) (enabled bool))
    (let (
        (recipe (unwrap! (get-crafting-recipe recipe-id) err-recipe-not-found))
    )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (map-set crafting-recipes recipe-id (merge recipe {enabled: enabled})))
    )
)

(define-public (create-time-limited-event (event-id uint) (recipe-id uint) (duration-blocks uint) (bonus-power uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (map-set time-limited-events event-id {
            recipe-id: recipe-id,
            start-block: stacks-block-height,
            end-block: (+ stacks-block-height duration-blocks),
            bonus-power: bonus-power,
            active: true
        }))
    )
)

(define-public (toggle-event (event-id uint) (active bool))
    (let (
        (event-data (unwrap! (get-time-limited-event event-id) err-recipe-not-found))
    )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (map-set time-limited-events event-id (merge event-data {active: active})))
    )
)

(define-public (set-crafting-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (var-set crafting-fee new-fee))
    )
)

(define-public (toggle-global-crafting (enabled bool))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (var-set global-crafting-enabled enabled))
    )
)

(define-public (emergency-mint (recipient principal) (name (string-ascii 64)) (rarity uint) (power uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (mint-crafted-nft recipient name rarity power (list))
    )
)

(define-public (list-nft (token-id uint) (price uint))
    (let (
        (token-owner (unwrap! (nft-get-owner? crafted-nft token-id) err-token-not-found))
    )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (asserts! (not (is-listed token-id)) err-already-listed)
        (asserts! (> price u0) err-invalid-recipe)
        (map-set marketplace-listings token-id {
            seller: tx-sender,
            price: price,
            listed-at: stacks-block-height
        })
        (ok true)
    )
)

(define-public (delist-nft (token-id uint))
    (let (
        (listing (unwrap! (get-listing token-id) err-not-listed))
        (token-owner (unwrap! (nft-get-owner? crafted-nft token-id) err-token-not-found))
    )
        (asserts! (is-eq tx-sender token-owner) err-not-token-owner)
        (asserts! (is-eq tx-sender (get seller listing)) err-not-token-owner)
        (map-delete marketplace-listings token-id)
        (ok true)
    )
)

(define-public (buy-nft (token-id uint))
    (let (
        (listing (unwrap! (get-listing token-id) err-not-listed))
        (seller (get seller listing))
        (price (get price listing))
        (token-owner (unwrap! (nft-get-owner? crafted-nft token-id) err-token-not-found))
    )
        (asserts! (is-eq seller token-owner) err-not-token-owner)
        (asserts! (not (is-eq tx-sender seller)) err-owner-only)
        (try! (stx-transfer? price tx-sender seller))
        (try! (nft-transfer? crafted-nft token-id seller tx-sender))
        (map-delete marketplace-listings token-id)
        (ok true)
    )
)
