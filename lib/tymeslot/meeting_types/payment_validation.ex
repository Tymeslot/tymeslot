defmodule Tymeslot.MeetingTypes.PaymentValidation do
  @moduledoc """
  The payment rules of a meeting type's changeset, kept apart from
  `Tymeslot.MeetingTypes.MeetingTypeSchema` like the reminder rules
  (`Tymeslot.MeetingTypes.ReminderValidation`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset,
    only: [
      add_error: 3,
      changed?: 2,
      get_change: 2,
      get_field: 2,
      validate_number: 3,
      validate_required: 2
    ]

  alias Tymeslot.MeetingPayments.Money

  @doc """
  Validates a meeting type changeset's payment fields: a price may only be set
  where it can be charged, and a type that asks for payment needs one at or
  above the currency's minimum.

  `opts` are the ones `MeetingTypeSchema.changeset/3` takes: `:price_settable`,
  `:host_charges_enabled`, `:currency_minimum_cents` and `:currency`.
  """
  @spec validate_changeset(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_changeset(changeset, opts) do
    changeset = validate_price_settable(changeset, opts)

    if get_field(changeset, :payment_required) do
      changeset
      |> validate_required([:price_cents])
      |> validate_currency_minimum(opts)
    else
      changeset
    end
  end

  # Asked when the host asks for payment or sets a price, not every time they
  # touch a meeting type that already has one. A paid type keeps its price
  # while it cannot be edited (Stripe disconnected, or an account in a legacy
  # currency that checkout still charges), so that it resumes as it was (see
  # `Tymeslot.MeetingTypes.FormMapper.build_attrs/3`); reading the stored
  # `true` with `get_field` would then fail every unrelated save, on a field
  # the form cannot render in that state. Turning payment off, which clears
  # the price, stays open.
  defp validate_price_settable(changeset, opts) do
    cond do
      Keyword.get(opts, :price_settable, false) ->
        changeset

      not price_edit?(changeset) ->
        changeset

      Keyword.get(opts, :host_charges_enabled, false) ->
        add_error(
          changeset,
          :payment_required,
          dgettext_noop("errors", "Prices cannot be set in your Stripe account's currency")
        )

      true ->
        add_error(
          changeset,
          :payment_required,
          dgettext_noop("errors", "Stripe must be connected")
        )
    end
  end

  defp price_edit?(changeset) do
    get_change(changeset, :payment_required) == true or
      (changed?(changeset, :price_cents) and not is_nil(get_field(changeset, :price_cents)))
  end

  defp validate_currency_minimum(changeset, opts) do
    minimum = Keyword.get(opts, :currency_minimum_cents, 50)
    currency = Keyword.get(opts, :currency, "usd")

    validate_number(changeset, :price_cents,
      greater_than_or_equal_to: minimum,
      message:
        dgettext("errors", "must be at least %{minimum}",
          minimum: Money.format(minimum, currency)
        )
    )
  end
end
