defmodule TymeslotWeb.Live.Shared.DocsUrl do
  @moduledoc """
  Docs links for templates: the article URL (`Tymeslot.Docs.article_url/1`,
  which owns the configurable base) and a ready-made anchor around it.
  """

  alias Tymeslot.Docs

  @doc """
  Builds the full URL to a docs article for the given slug.
  """
  @spec article_url(String.t()) :: String.t()
  defdelegate article_url(slug), to: Docs

  @doc """
  Builds an `<a>` tag linking to a docs article, for callers that render the
  anchor inline rather than composing it themselves around `article_url/1`.
  """
  @spec article_link(String.t(), String.t()) :: String.t()
  def article_link(slug, label) do
    ~s(<a href="#{article_url(slug)}" target="_blank" rel="noopener noreferrer" class="font-black text-turquoise-700 hover:text-turquoise-900 underline">#{label}</a>)
  end
end
