defmodule Tymeslot.Security.FieldValidators.UrlValidator do
  @moduledoc """
  Validates URLs limited to http/https schemes.

  Delegates to `Tymeslot.Security.UrlValidation.validate_http_url/2` for
  the core logic, adding optional/required blank-value handling consistent
  with the other FieldValidators.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.UrlValidation

  @spec validate(any(), keyword()) :: :ok | {:error, String.t()}
  def validate(value, opts \\ [])

  def validate(nil, opts), do: blank(opts)
  def validate("", opts), do: blank(opts)

  def validate(value, _opts) when is_binary(value) do
    UrlValidation.validate_http_url(String.trim(value))
  end

  def validate(_value, _opts), do: {:error, dgettext("errors_input", "URL must be text")}

  defp blank(opts) do
    if Keyword.get(opts, :required, true),
      do: {:error, dgettext("errors_input", "URL is required")},
      else: :ok
  end
end
