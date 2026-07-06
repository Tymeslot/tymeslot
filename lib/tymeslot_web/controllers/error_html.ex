defmodule TymeslotWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use TymeslotWeb, :html

  alias Phoenix.Controller

  # A branded, self-contained 404 page lives in `error_html/404.html.heex` and is
  # picked up by `embed_templates` as the `render("404.html", assigns)` clause.
  # Every other status falls through to the plain-text clause below.
  embed_templates "error_html/*"

  # The default is to render a plain text page based on
  # the template name. For example, "500.html" becomes
  # "Internal Server Error".
  @spec render(String.t(), map()) :: Phoenix.LiveView.Rendered.t() | String.t()
  def render(template, _assigns) do
    Controller.status_message_from_template(template)
  end
end
