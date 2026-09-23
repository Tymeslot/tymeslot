defmodule Tymeslot.Infrastructure.TokenBehaviour do
  @moduledoc """
  Behaviour for token-related operations used in Auth.
  """
  @callback generate_session_token(integer()) :: {String.t(), DateTime.t()}
end
