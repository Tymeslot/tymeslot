defmodule Tymeslot.Emails.Shared.SignInProvider do
  @moduledoc """
  How an account signs in, as account emails name it: whether it has a
  password at all, and the name of the provider it uses otherwise.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Whether the account signs in through a provider rather than a password.
  """
  @spec social?(map()) :: boolean()
  def social?(%{provider: provider}) when provider not in [nil, "email"], do: true
  def social?(_user), do: false

  @doc """
  The provider's name for use inside a sentence ("signs in with %{provider}").
  """
  @spec display_name(map()) :: String.t()
  def display_name(%{provider: "google"}), do: "Google"
  def display_name(%{provider: "github"}), do: "GitHub"
  def display_name(_user), do: dgettext("emails", "single sign-on")
end
