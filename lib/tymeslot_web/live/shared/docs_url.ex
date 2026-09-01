defmodule TymeslotWeb.Live.Shared.DocsUrl do
  @moduledoc """
  Builds links into the docs hub.

  The docs hub is a hosted site that standalone Core does not serve, so the
  default points there; an operator running their own docs sets
  `:docs_article_base_url` and every link in the dashboard and the
  feature-announcement modal (`Tymeslot.Announcements.docs_url/1`) follows.
  This is the single place that key is read and normalised.
  """

  @default_base_url "https://tymeslot.app/docs"

  @doc """
  Builds the full URL to a docs article for the given slug.
  """
  @spec article_url(String.t()) :: String.t()
  def article_url(slug), do: "#{base_url()}/#{slug}"

  @doc """
  Builds an `<a>` tag linking to a docs article, for callers that render the
  anchor inline rather than composing it themselves around `article_url/1`.
  """
  @spec article_link(String.t(), String.t()) :: String.t()
  def article_link(slug, label) do
    ~s(<a href="#{article_url(slug)}" target="_blank" rel="noopener noreferrer" class="font-black text-turquoise-700 hover:text-turquoise-900 underline">#{label}</a>)
  end

  # Read at runtime, not through `compile_env/3`: Core ships as a prebuilt
  # image, so a self-hoster pointing this at their own docs configures it on
  # the running instance and cannot recompile to pick up a module attribute.
  # Rendering a handful of dashboard links is not a hot path, so the lookup
  # costs nothing worth reclaiming. Trailing slashes are trimmed here so an
  # operator-set base of either form joins the slug with exactly one `/`.
  defp base_url do
    :tymeslot
    |> Application.get_env(:docs_article_base_url, @default_base_url)
    |> String.trim_trailing("/")
  end
end
