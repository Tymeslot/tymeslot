defmodule TymeslotWeb.Components.CoreComponents.TranslatedLink do
  @moduledoc """
  Builds anchor markup as an HTML string, for interpolation into a single translated msgid.

  A sentence containing a link must be one msgid, not a run of fragments glued around an
  `<a>` tag — translators need to move the link to wherever the target language's word order
  puts it. So the anchor is rendered to a string and passed in as a gettext binding:

      {raw(
         dgettext("auth", "See the %{terms} and %{privacy} for details.",
           terms: link_html(dgettext("auth", "terms"), href: ~p"/legal/terms"),
           privacy: link_html(dgettext("auth", "privacy policy"), href: ~p"/legal/privacy")
         ))}

  ## Safety

  The result is interpolated into a string that the caller wraps in `raw/1`, so it must never
  carry user data. Every attribute value is escaped with `Phoenix.HTML.attributes_escape/1` and
  the label with `Phoenix.HTML.html_escape/1`, but escaping is a backstop, not a licence:

    * `label` must be a developer-authored or repo-controlled (translated) string.
    * `attrs` values must be static — a route, a CSS class, an analytics payload you built.

  Never pass an attendee name, an account email, a user-entered domain, or any other
  user-controlled value through here. For sentences that interpolate user data, use plain
  `dgettext/3` with bindings and let HEEx escape on render — no `raw/1` at all.
  """

  alias Phoenix.HTML

  @doc """
  Renders `<a {attrs}>label</a>` as an escaped HTML string.

  `attrs` is any enumerable accepted by `Phoenix.HTML.attributes_escape/1`; attribute order is
  preserved, so callers can keep rendered output byte-identical to hand-written markup.
  """
  @spec link_html(String.t(), Enumerable.t()) :: String.t()
  def link_html(label, attrs) do
    "<a" <> escaped_attrs(attrs) <> ">" <> escaped(label) <> "</a>"
  end

  defp escaped_attrs(attrs), do: attrs |> HTML.attributes_escape() |> HTML.safe_to_string()
  defp escaped(text), do: text |> HTML.html_escape() |> HTML.safe_to_string()
end
