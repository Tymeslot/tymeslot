# Stripe API response fixtures

Stripe objects as the API returns them at the version Tymeslot pins, loaded by `Tymeslot.StripeFixtures` and served by `Tymeslot.StripeStub`. Each file holds only the Stripe object. Ids are replaced with stable fake ones (`cus_test1`, `ch_test1`, `re_test1`, `cs_test1`, `pi_test1`, `sub_test1`, `in_test1`, `inpay_test1`, `dp_test1`, `acct_test1`, `bps_test1`) wherever they appear, including cross-references and URLs; other ids (prices, products, balance transactions) are kept as Stripe printed them. Opaque secrets in the examples (a payment intent's `client_secret`, the secret in a billing portal session's `url`) are replaced with fake ones too, so the secret scan does not flag them.

The reference pages were read at `docs.stripe.com/api/<resource>/object?api-version=2025-11-17.clover`. Where a file is a state the reference does not show, it is that resource's example with the fields named below changed.

## `2025-11-17.clover/`

| File | Provenance |
|---|---|
| `customer.json` | recorded 2026-11-26 |
| `customer_deleted.json` | recorded 2026-11-26 |
| `checkout_session_payment.json` | recorded 2026-11-26: an open payment-mode session has `payment_intent: null`, as in the `checkout/sessions/create` response example |
| `checkout_session_paid.json` | API reference example (`checkout/sessions/object`), fetched 2026-11-22; `status: "complete"`, `payment_status: "paid"`, `payment_intent` set, `url: null` |
| `checkout_session_subscription.json` | recorded 2026-11-26; `mode: "subscription"`, `customer` set |
| `checkout_session_expired.json` | recorded 2026-11-26; `status: "expired"`, `url: null` |
| `subscription.json` | recorded 2026-11-26 |
| `subscription_canceling.json` | recorded 2026-11-26; `cancel_at_period_end: true`, `cancel_at` at the item's period end, `canceled_at`, `cancellation_details.reason` |
| `subscription_canceled.json` | recorded 2026-11-26; `status: "canceled"`, `canceled_at`, `ended_at`, `cancellation_details.reason` |
| `charge.json` | recorded 2026-11-26; `payment_intent` set |
| `charge_with_refunds.json` | recorded 2026-11-26; `amount_refunded` and an expanded `refunds` list holding `refund.json` |
| `invoice.json` | recorded 2026-11-26 |
| `invoice_payment.json` | API reference example (`invoice-payment/object`), fetched 2026-11-22 |
| `refund.json` | recorded 2026-11-26 |
| `refund_with_charge.json` | recorded 2026-11-26; `charge` expanded to `charge.json` with `amount_refunded` set |
| `payment_intent_with_latest_charge.json` | recorded 2026-11-26; `status: "succeeded"`, amounts matching the charge, `payment_method`, `latest_charge` expanded to `charge.json` |
| `dispute_lost.json` | API reference example (`disputes/object`), fetched 2026-11-22; `status: "lost"`, `is_charge_refundable: false`, `charge` and `payment_intent` set |
| `account.json` | recorded 2026-11-26 |
| `billing_portal_session.json` | recorded 2026-11-26 |

## `2025-11-17.clover/errors/`

Each file is `{"status": <HTTP status>, "body": <response body>}`. The reference shows no example error body, so each is built from the attributes of the error object (`docs.stripe.com/api/errors`) and the codes in `docs.stripe.com/error-codes`, fetched 2026-11-22.

| File | Status | `type` | `code` |
|---|---|---|---|
| `resource_missing.json` | 404 | `invalid_request_error` | `resource_missing` |
| `idempotency_error.json` | 400 | `idempotency_error` | none |
| `invalid_request_error.json` | 400 | `invalid_request_error` | `parameter_unknown` |
| `charge_already_refunded.json` | 400 | `invalid_request_error` | `charge_already_refunded` |
| `card_error.json` | 402 | `card_error` | `card_declined` (`decline_code: "generic_decline"`) |
| `rate_limit.json` | 429 | `invalid_request_error` | `rate_limit` |
| `api_error.json` | 500 | `api_error` | none |
