defmodule Tymeslot.Security.Encryption.ConfigError do
  @moduledoc """
  A data-at-rest key configuration that cannot work. `:reason` says what is
  wrong and `:fix` what the operator should do about it; neither ever includes
  key material.
  """

  defexception [:reason, :fix]

  @type t :: %__MODULE__{reason: String.t(), fix: String.t()}

  @impl Exception
  def message(%__MODULE__{reason: reason, fix: fix}), do: "#{reason}. #{fix}."
end
