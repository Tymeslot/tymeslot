defmodule Tymeslot.Repo.Migrations.BackfillLastChargeCurrencyOnProfiles do
  use Ecto.Migration

  @moduledoc """
  Gives a host who disconnected Stripe before `profiles.last_charge_currency`
  existed the currency of their most recent booking payment.

  Such a host kept their prices but the column is NULL, so reconnecting to an
  account in another currency would silently turn 50 CHF into 50 GBP. Only
  profiles whose value is NULL are touched, and a host with no payments is
  left as they are. Currencies are stored lower case, as
  `booking_payments.currency` holds them.

  Irreversible in content and harmless to leave in place, so `down/0` does
  nothing.
  """

  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # A one-off data backfill: it has no changeset to run through and touches
  # only rows whose value is still NULL.
  def up do
    execute("""
    UPDATE profiles AS p
    SET last_charge_currency = latest.currency
    FROM (
      SELECT DISTINCT ON (host_user_id) host_user_id, lower(currency) AS currency
      FROM booking_payments
      WHERE currency IS NOT NULL AND char_length(currency) = 3
      ORDER BY host_user_id, inserted_at DESC, id DESC
    ) AS latest
    WHERE p.user_id = latest.host_user_id
      AND p.last_charge_currency IS NULL
    """)
  end

  def down, do: :ok
end
