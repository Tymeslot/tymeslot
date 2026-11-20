defmodule TymeslotWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  alias Phoenix.Controller

  # The detail is the status message derived from the template name: for
  # example, "404.json" becomes "Not Found".
  @spec render(String.t(), map()) :: map()
  def render(template, _assigns) do
    %{errors: %{detail: Controller.status_message_from_template(template)}}
  end
end
