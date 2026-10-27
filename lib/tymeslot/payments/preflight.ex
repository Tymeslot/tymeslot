defmodule Tymeslot.Payments.Preflight do
  @moduledoc false

  alias Tymeslot.Payments.{MetadataSanitizer, Validation}
  alias Tymeslot.Security.RateLimiter

  @spec sanitize_initiation(pos_integer(), pos_integer(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def sanitize_initiation(amount, user_id, metadata, system_metadata) do
    with :ok <- Validation.validate_amount(amount),
         :ok <- check_rate_limit(user_id) do
      MetadataSanitizer.sanitize(metadata, system_metadata)
    end
  end

  defp check_rate_limit(user_id) do
    case RateLimiter.check(:payment_initiation, user_id) do
      {:error, :rate_limited, _message} -> {:error, :rate_limited}
      other -> other
    end
  end
end
