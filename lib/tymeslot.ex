defmodule Tymeslot do
  @moduledoc """
  Tymeslot keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  Returns the application name for display purposes.
  """
  @spec get_app_name() :: String.t()
  def get_app_name do
    Application.get_env(:tymeslot, :app_name, "Tymeslot")
  end
end
