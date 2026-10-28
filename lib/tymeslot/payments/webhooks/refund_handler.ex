defmodule Tymeslot.Payments.Webhooks.RefundHandler do
  @moduledoc """
  Handles Stripe refund webhook events.

  CRITICAL: a full refund must end the subscription it paid for, or the user
  keeps Pro access and is billed again. This handler decides whether a refund
  revokes access and hands that decision, with the invoice the refunded
  charge paid and the subscription that invoice billed (read from Stripe
  when not recorded here), to the configured payment-event handler, which is
  the one place access is revoked (cancelling the subscription at Stripe as
  well as locally). A handler failure, or a Stripe lookup failure, fails the
  delivery, so Stripe redelivers the refund. The handler itself then tells
  the user.

  ## Partial Refund Handling

  The handler now supports proper partial refund handling:
  - Calculates total refunded amount across all refunds for a charge
  - Only revokes access when total refunds exceed a configurable threshold
  - Default threshold: 90% of the original charge amount
  - Prevents unfair subscription cancellations for small partial refunds

  ## Configuration

      config :tymeslot, :refund_revocation_threshold_percent, 90

  ## Refunds the app has already announced

  A refund the app issued itself, and told the customer about as it did,
  carries `"customer_notified" => "true"` in its Stripe metadata. The
  handler still revokes and alerts as for any refund, but sends no refund
  email of its own, which would repeat the app's message and could
  contradict it.

  The refund an event is about is told apart from the charge's other
  refunds by its amount: the rise in `amount_refunded` over the previous
  value the event records. When that leaves more than one refund, the email
  is skipped only if every one of them was announced.

  Events handled:
  - charge.refunded: Refund has been issued
  - charge.refund.updated: Refund status changed
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Payments.Behaviours.WebhookHandler
  alias Tymeslot.Payments.ChargeInvoice
  alias Tymeslot.Payments.Config
  alias Tymeslot.Payments.CustomerLookup
  alias Tymeslot.Payments.PubSub
  alias Tymeslot.Payments.SubscriptionInvoices
  alias Tymeslot.Payments.Webhooks.WebhookUtils
  alias Tymeslot.Utils.MapKeys

  # Stripe statuses of a subscription that still exists and bills, or can
  # resume billing. A refund only revokes one of these: an incomplete or
  # paused subscription has nothing to revoke.
  @live_subscription_statuses ~w(active trialing past_due unpaid)

  # Stripe's largest page. A charge is refunded a handful of times at most.
  @refunds_read_per_charge 100

  @impl WebhookHandler
  def handle(
        %{"type" => "charge.refunded", "data" => %{"object" => %{"id" => _id} = charge}} = event
      ),
      do: handle_refunded(event, charge)

  def handle(
        %{"type" => "charge.refund.updated", "data" => %{"object" => %{"id" => _id} = refund}} =
          event
      ),
      do: handle_refund_updated(event, refund)

  def handle(_event), do: {:error, :permanent, :missing_fields}

  # Private functions

  defp handle_refunded(event, charge) do
    charge_id = charge["id"]
    charge_amount = get_charge_amount(charge)
    total_refunded = calculate_total_refunded(charge)
    customer_id = charge["customer"]
    # Check if refund exceeds threshold before revoking access. Computed up
    # front (it depends only on the charge, not on a local subscription
    # lookup) so the broadcast below can carry the decision instead of
    # leaving the configured payment-event handler to re-derive (or skip) it.
    should_revoke = should_revoke_access?(total_refunded, charge_amount)

    Logger.info("Refund received",
      charge_id: charge_id,
      customer_id: customer_id,
      total_refunded: total_refunded,
      charge_amount: charge_amount,
      refund_percentage: calculate_refund_percentage(total_refunded, charge_amount),
      stripe_event_id: event["id"]
    )

    case paid_for(charge, should_revoke) do
      {:ok, %{invoice_id: invoice_id, subscription_id: subscription_id}} ->
        hand_off_refund(event, charge, %{
          charge_id: charge_id,
          customer_id: customer_id,
          invoice_id: invoice_id,
          subscription_id: subscription_id,
          total_refunded: total_refunded,
          charge_amount: charge_amount,
          should_revoke: should_revoke
        })

      {:error, reason} ->
        {:error, :retry_later, reason}
    end
  end

  # The invoice the refunded charge paid and the subscription it billed. A
  # refund that revokes access needs the subscription for certain, so it is
  # read from Stripe whenever the charge or the recorded invoices do not
  # say: an invoice recorded before invoices were kept here, or a charge
  # rendered at an API version that no longer names its invoice. Without a
  # subscription manager there is no subscription to revoke, and a refund
  # below the threshold revokes nothing, so both settle for what is known
  # locally.
  defp paid_for(charge, true = _should_revoke) do
    if Config.subscription_manager(),
      do: ChargeInvoice.for_charge(charge),
      else: paid_for(charge, false)
  end

  defp paid_for(charge, false = _should_revoke) do
    invoice_id = charge["invoice"]

    {:ok,
     %{
       invoice_id: invoice_id,
       subscription_id: SubscriptionInvoices.subscription_id_for_invoice(invoice_id)
     }}
  end

  defp hand_off_refund(event, charge, refund) do
    # Hand the refund to the configured payment-event handler first: if it
    # fails, nothing below has run yet and Stripe redelivers the event. The
    # subscription the charge paid for lets the handler revoke that
    # subscription rather than whichever one the customer holds now.
    payment_event =
      refund
      |> Map.put(:event_id, event["id"])
      |> Map.put(
        :refund_percentage,
        calculate_refund_percentage(refund.total_refunded, refund.charge_amount)
      )

    case PubSub.hand_off_payment_event(:charge_refunded, payment_event) do
      :ok -> handle_refunded_locally(event, charge, refund)
      {:error, reason} -> {:error, :retry_later, {:hand_off_failed, reason}}
    end
  end

  defp handle_refunded_locally(event, charge, refund) do
    %{
      charge_id: charge_id,
      customer_id: customer_id,
      total_refunded: total_refunded,
      charge_amount: charge_amount,
      should_revoke: should_revoke
    } = refund

    # Find the subscription by Stripe customer ID for local notifications
    case CustomerLookup.get_subscription_by_customer_id(customer_id) do
      nil ->
        Logger.warning("Refund unlinked - no subscription found",
          charge_id: charge_id,
          customer_id: customer_id
        )

        # Alert admin about unlinked refund
        AdminAlerts.report(:unlinked_refund,
          summary: "Unlinked refund received — no matching subscription",
          reason: {:no_subscription_for_customer, customer_id},
          context: %{
            charge_id: charge_id,
            customer_id: customer_id,
            total_refunded: total_refunded,
            charge_amount: charge_amount
          }
        )

        {:ok, :refund_logged}

      subscription ->
        # Revoking access is the payment-event handler's job: it received
        # this refund, with the decision, above, and has not acted on it
        # yet. Here the user is told, and told access ends only when the
        # refund is for the subscription they hold now.
        revoked = should_revoke and refunds_current_subscription?(refund, subscription)
        access = access_outcome(should_revoke, revoked)

        if !should_revoke do
          Logger.info("Refund below threshold - not revoking access",
            user_id: subscription.user_id,
            charge_id: charge_id,
            total_refunded: total_refunded,
            charge_amount: charge_amount,
            refund_percentage: calculate_refund_percentage(total_refunded, charge_amount),
            threshold: refund_revocation_threshold_percent()
          )
        end

        # Alert admin about processed refund
        AdminAlerts.report(:refund_processed,
          summary: "Refund processed for subscription",
          context: %{
            user_id: subscription.user_id,
            charge_id: charge_id,
            total_refunded: total_refunded,
            charge_amount: charge_amount,
            access_revoked: revoked
          }
        )

        # Send email notification to user, quoting the amount of THIS
        # refund rather than the cumulative total across the charge.
        notify_unless_announced(subscription, event, charge, access)

        {:ok, :refund_processed}
    end
  end

  # What the refund email tells the customer about their access, as a
  # string because it travels in the email job's JSON arguments. A refund
  # past the threshold that revokes nothing (the subscription already ended,
  # or the charge paid for an earlier one) is neither partial nor revoking.
  defp access_outcome(false = _should_revoke, _revoked), do: "partial"
  defp access_outcome(true, true = _revoked), do: "revoked"
  defp access_outcome(true, false), do: "unaffected"

  # Whether the refunded charge paid for the subscription the customer holds
  # now, and that subscription is still live. A charge whose invoice billed
  # no subscription (or that paid no invoice) refunds none; one whose
  # invoice billed a different subscription paid for an earlier one, and
  # the customer keeps the subscription they hold now.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec refunds_current_subscription?(map(), map()) :: boolean()
  def refunds_current_subscription?(%{subscription_id: nil}, _subscription), do: false

  def refunds_current_subscription?(%{subscription_id: subscription_id}, subscription) do
    Map.get(subscription, :status) in @live_subscription_statuses and
      subscription_id == Map.get(subscription, :stripe_subscription_id)
  end

  defp handle_refund_updated(_event, refund) do
    refund_id = refund["id"]
    status = refund["status"]

    Logger.info("Refund status updated", refund_id: refund_id, status: status)

    # Track refund status changes (succeeded, failed, pending)
    # This is mainly for logging/auditing purposes
    {:ok, :refund_status_updated}
  end

  # Calculates the total amount refunded across all refunds for a charge.
  # Handles both Stripe's expanded refunds list and the amount_refunded summary field.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec calculate_total_refunded(map()) :: non_neg_integer()
  def calculate_total_refunded(charge) do
    # First try to get from amount_refunded (most reliable)
    case MapKeys.get(charge, :amount_refunded) do
      amount when is_integer(amount) and amount > 0 ->
        amount

      _amount_other ->
        # Fall back to summing individual refunds
        charge
        |> get_refunds()
        |> Enum.reduce(0, &(refund_amount(&1) + &2))
    end
  end

  defp refund_amount(refund) do
    case MapKeys.get(refund, :amount) do
      amount when is_integer(amount) and amount > 0 -> amount
      _amount_other -> 0
    end
  end

  # Determines the amount refunded by the specific event that triggered this
  # webhook, rather than the cumulative total across every refund on the
  # charge. Uses the most recently created entry in the refunds list; when
  # that list is unavailable (e.g. only the summary `amount_refunded` field
  # was sent), the cumulative total is the best available approximation —
  # it equals the delta for a charge's first refund.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec calculate_latest_refund_amount(map()) :: non_neg_integer()
  def calculate_latest_refund_amount(charge) do
    case latest_refund(charge) do
      nil -> calculate_total_refunded(charge)
      refund -> MapKeys.get(refund, :amount) || calculate_total_refunded(charge)
    end
  end

  # Gets the original charge amount.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec get_charge_amount(map()) :: non_neg_integer()
  def get_charge_amount(charge) do
    MapKeys.get(charge, :amount) || 0
  end

  # Sends the refund email unless the app already announced this refund
  # (see the moduledoc). The event is about one refund, but a charge can
  # carry several, and a late delivery can arrive after a later refund was
  # issued, so the newest refund is not necessarily this event's. The event's
  # own refund is the one whose amount is the rise in `amount_refunded` the
  # event records against its previous value; without that value every
  # refund on the charge is a candidate.
  #
  # The email is skipped only when every candidate was announced, so a
  # notice is never lost to an ambiguous match: a repeated notice is the
  # lesser harm next to a refund nobody is told about. The same holds when
  # the refunds cannot be read at all.
  defp notify_unless_announced(subscription, event, charge, access) do
    delta = refunded_by_event(event, charge)

    case candidate_refunds(charge, delta) do
      [_first | _rest] = candidates ->
        unless Enum.all?(candidates, &customer_notified?/1) do
          amount = delta || newest_unannounced_amount(candidates, charge)
          send_refund_email(subscription, amount, access, charge)
        end

      [] ->
        amount = delta || calculate_latest_refund_amount(charge)
        send_refund_email(subscription, amount, access, charge)
    end
  end

  # The amount this event refunded: the rise in the charge's
  # `amount_refunded` over the value Stripe reports as previous. `nil` when
  # the event does not record it.
  defp refunded_by_event(event, charge) do
    previous = get_in(event, ["data", "previous_attributes", "amount_refunded"])
    current = MapKeys.get(charge, :amount_refunded)

    if is_integer(previous) and is_integer(current) and current > previous,
      do: current - previous,
      else: nil
  end

  defp candidate_refunds(charge, nil), do: charge_refunds(charge)

  defp candidate_refunds(charge, delta),
    do: charge |> charge_refunds() |> Enum.filter(&(MapKeys.get(&1, :amount) == delta))

  # A webhook charge carries its refunds only at older API versions, so when
  # they are missing they are read from Stripe. An unreadable list is no
  # candidates, which sends the email.
  defp charge_refunds(charge) do
    with [] <- get_refunds(charge),
         {:ok, %{data: refunds}} when is_list(refunds) <-
           Config.stripe_provider().list_refunds(%{
             charge: charge["id"],
             limit: @refunds_read_per_charge
           }) do
      refunds
    else
      [_first | _rest] = refunds ->
        refunds

      other ->
        Logger.info("Refunds not readable; sending the refund email",
          charge_id: charge["id"],
          reason: LogFormat.reason(other)
        )

        []
    end
  end

  defp newest_unannounced_amount(candidates, charge) do
    newest =
      candidates
      |> Enum.reject(&customer_notified?/1)
      |> Enum.max_by(&(MapKeys.get(&1, :created) || 0), fn -> %{} end)

    MapKeys.get(newest, :amount) || calculate_latest_refund_amount(charge)
  end

  defp customer_notified?(refund),
    do: MapKeys.get(MapKeys.get(refund, :metadata) || %{}, :customer_notified) == "true"

  defp latest_refund(charge),
    do: Enum.max_by(get_refunds(charge), &(MapKeys.get(&1, :created) || 0), fn -> nil end)

  # The list of individual refunds sits one level below the charge, under
  # "refunds"/"data" (or their atom-keyed equivalents).
  defp get_refunds(charge) do
    case MapKeys.get(charge, :refunds) do
      nil -> []
      refunds -> MapKeys.get(refunds, :data) || []
    end
  end

  # Calculates the refund percentage.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec calculate_refund_percentage(non_neg_integer(), non_neg_integer()) :: float()
  def calculate_refund_percentage(_refunded, 0), do: 0.0

  def calculate_refund_percentage(refunded, charge_amount) do
    Float.round(refunded / charge_amount * 100.0, 2)
  end

  # Determines if access should be revoked based on refund threshold.
  # Access is revoked if total refunded amount exceeds the configured threshold
  # percentage of the original charge amount.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec should_revoke_access?(non_neg_integer(), non_neg_integer()) :: boolean()
  def should_revoke_access?(_refunded, 0), do: false

  def should_revoke_access?(refunded, charge_amount) do
    threshold_percent = refund_revocation_threshold_percent()
    refund_percent = calculate_refund_percentage(refunded, charge_amount)

    refund_percent >= threshold_percent
  end

  # Gets the refund revocation threshold percentage from config.
  @spec refund_revocation_threshold_percent() :: float()
  defp refund_revocation_threshold_percent do
    Application.get_env(:tymeslot, :refund_revocation_threshold_percent, 90.0)
  end

  # Extracts the currency from a charge object, supporting both string and atom keys.
  # Defaults to "eur" when the field is absent.
  # Made public for testing purposes but should be considered internal API.
  @doc false
  @spec extract_charge_currency(map()) :: String.t()
  def extract_charge_currency(charge) do
    MapKeys.get(charge, :currency) || "eur"
  end

  defp send_refund_email(subscription, refund_amount_cents, access, charge) do
    currency = extract_charge_currency(charge)

    WebhookUtils.deliver_user_email(
      subscription.user_id,
      :refund_processed_template,
      :refund_processed_email,
      [refund_amount_cents, currency, access],
      success_msg: "Refund notification sent to user #{subscription.user_id}",
      error_msg: "Failed to send refund notification: ",
      standalone_msg: "Refund processed template not configured (Standalone mode)"
    )
  end
end
