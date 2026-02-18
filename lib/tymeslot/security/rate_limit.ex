defmodule Tymeslot.Security.RateLimit do
  @moduledoc """
  Hammer-backed ETS rate limiter using the sliding window algorithm.

  The sliding window algorithm prevents the 2× burst at window boundaries that
  fixed windows allow, making it appropriate for security-sensitive rate limiting.
  """

  use Hammer, backend: :ets, algorithm: :sliding_window
end
