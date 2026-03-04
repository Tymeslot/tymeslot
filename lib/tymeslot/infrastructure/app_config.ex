defmodule Tymeslot.Infrastructure.AppConfigBehaviour do
  @moduledoc """
  Behaviour for application-wide configuration that might differ between Core and SaaS.
  """

  @callback registration_enabled?() :: boolean()
  @callback password_auth_enabled?() :: boolean()
  @callback enforce_legal_agreements?() :: boolean()
  @callback show_marketing_links?() :: boolean()
  @callback logo_links_to_marketing?() :: boolean()
  @callback site_home_path() :: String.t()
end

defmodule Tymeslot.Infrastructure.AppConfig do
  @moduledoc """
  Default implementation of AppConfigBehaviour for Tymeslot Core.
  """
  @behaviour Tymeslot.Infrastructure.AppConfigBehaviour

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  def registration_enabled? do
    Application.get_env(:tymeslot, :registration_enabled, true)
  end

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  def password_auth_enabled? do
    Application.get_env(:tymeslot, :password_auth_enabled, true)
  end

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  def enforce_legal_agreements? do
    Application.get_env(:tymeslot, :enforce_legal_agreements, false)
  end

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  def show_marketing_links? do
    Application.get_env(:tymeslot, :show_marketing_links, false)
  end

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  def logo_links_to_marketing? do
    Application.get_env(:tymeslot, :logo_links_to_marketing, false)
  end

  @impl Tymeslot.Infrastructure.AppConfigBehaviour
  def site_home_path do
    Application.get_env(:tymeslot, :site_home_path, "/dashboard")
  end
end
