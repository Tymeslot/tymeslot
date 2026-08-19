defmodule TymeslotWeb.Live.Shared.DocsUrl do
  @moduledoc """
  Builds links into the docs hub.

  The docs hub is a hosted site that standalone Core does not serve, so the
  default points there; an operator running their own docs sets
  `:docs_article_base_url` and every link in the dashboard follows.
  """

  @default_base_url "https://tymeslot.app/docs"

  @doc """
  Builds the full URL to a docs article for the given slug.
  """
  @spec article_url(String.t()) :: String.t()
  def article_url(slug), do: "#{base_url()}/#{slug}"

  # Read at runtime, not through `compile_env/3`: Core ships as a prebuilt
  # image, so a self-hoster pointing this at their own docs configures it on
  # the running instance and cannot recompile to pick up a module attribute.
  # Rendering a handful of dashboard links is not a hot path, so the lookup
  # costs nothing worth reclaiming.
  defp base_url do
    Application.get_env(:tymeslot, :docs_article_base_url, @default_base_url)
  end
end
