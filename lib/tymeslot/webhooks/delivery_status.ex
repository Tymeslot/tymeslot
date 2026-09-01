defmodule Tymeslot.Webhooks.DeliveryStatus do
  @moduledoc """
  Encodes and decodes `WebhookSchema.last_status`, which packs delivery
  state and (for failures) a free-form reason into one string column.

  Both sides of that contract go through this module rather than matching
  the raw string independently, so a writer that changes the failure
  encoding cannot silently stop matching a reader that still expects the
  old shape.
  """

  @failure_prefix "failed: "

  @type state :: :success | :failed | :unknown

  @doc "The value `WebhookQueries.record_success/2` stores."
  @spec encode_success() :: String.t()
  def encode_success, do: "success"

  @doc "The value `WebhookQueries.increment_failure_count/2` stores."
  @spec encode_failure(String.t()) :: String.t()
  def encode_failure(reason), do: @failure_prefix <> reason

  @doc "Decodes a stored `last_status` into its delivery state."
  @spec state(String.t() | nil) :: state()
  def state("success"), do: :success
  def state(@failure_prefix <> _reason), do: :failed
  def state(_other), do: :unknown

  @doc "Decodes a stored `last_status` into the failure reason, if any."
  @spec reason(String.t() | nil) :: String.t() | nil
  def reason(@failure_prefix <> reason), do: reason
  def reason(_other), do: nil
end
