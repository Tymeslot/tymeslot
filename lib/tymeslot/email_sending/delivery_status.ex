defmodule Tymeslot.EmailSending.DeliveryStatus do
  @moduledoc """
  Fixed owner-visible SMTP failure categories, without relay replies or secrets.

  A transport acceptance clears an earlier failure. Recipient and local
  capacity refusals say nothing about the owner's account health, and an
  ambiguous timeout must remain a failure even when job policy assumes delivery.
  """

  @write_deadline_ms 250
  @codes ~w(authentication_failed tls_required dns_failed invalid_destination
            credentials_unavailable invalid_settings not_tested session_timeout
            ambiguous_timeout delivery_failed)
  @ignored [
    :recipient_rejected,
    :rate_limited,
    :circuit_open,
    :connection_unavailable,
    :breaker_unavailable,
    :settings_changed,
    :invalid_sender,
    :feature_disabled,
    :owner_not_found
  ]

  @type outcome :: :healthy | {:failure, String.t()} | :ignore

  @doc "The bounded database budget for recording one SMTP outcome, in milliseconds."
  @spec write_deadline_ms() :: pos_integer()
  def write_deadline_ms, do: @write_deadline_ms

  @doc "Returns only a fixed public status code; unknown stored data becomes generic."
  @spec sanitize(term()) :: String.t() | nil
  def sanitize(nil), do: nil
  def sanitize(code) when code in @codes, do: code
  def sanitize(_code), do: "delivery_failed"

  @doc "Classifies a sanitized transport outcome before the job applies timeout policy."
  @spec outcome(term()) :: outcome()
  def outcome({:ok, :accepted}), do: :healthy
  def outcome({:error, reason}) when reason in @ignored, do: :ignore
  def outcome({:error, {:recipient_rejected, _details}}), do: :ignore

  def outcome({:error, reason}) when is_atom(reason),
    do: {:failure, sanitize(Atom.to_string(reason))}

  def outcome({:error, _unknown}), do: {:failure, "delivery_failed"}
  def outcome(_result), do: :ignore
end
