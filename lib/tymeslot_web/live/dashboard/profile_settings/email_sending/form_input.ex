defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSending.FormInput do
  @moduledoc """
  Projects SMTP form input into public values without retaining credentials.

  The submitted credential fields are passed straight to the domain operation.
  Only public fields enter socket assigns or a rendered form value.
  """

  alias Ecto.Changeset
  alias Tymeslot.EmailSending.Settings

  @public_fields [:host, :port, :security, :from_address, :from_name]
  @fields ~w(host port security username password from_address from_name)

  @doc "The editable field names accepted by this form."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "Discards submitted ownership, revision and lifecycle fields."
  @spec attributes(term()) :: map()
  def attributes(params) when is_map(params), do: Map.take(params, @fields)
  def attributes(_params), do: %{}

  @doc "Keeps the two standard port/TLS selections aligned during editing."
  @spec align_transport(map(), [String.t()] | nil) :: map()
  def align_transport(params, ["smtp", "port"]) do
    case params["port"] do
      "465" -> Map.put(params, "security", "implicit_tls")
      "587" -> Map.put(params, "security", "starttls")
      _invalid -> params
    end
  end

  def align_transport(params, ["smtp", "security"]) do
    case params["security"] do
      "implicit_tls" -> Map.put(params, "port", "465")
      "starttls" -> Map.put(params, "port", "587")
      _invalid -> params
    end
  end

  def align_transport(params, _target), do: params

  @doc "Builds nonsecret values from domain validation or a saved public view."
  @spec values(Changeset.t() | Settings.t() | nil) :: %{String.t() => String.t()}
  def values(%Changeset{} = changeset),
    do: Map.new(@public_fields, &{Atom.to_string(&1), text(Changeset.get_field(changeset, &1))})

  def values(%Settings{} = settings),
    do: Map.new(@public_fields, &{Atom.to_string(&1), text(Map.fetch!(settings, &1))})

  def values(nil),
    do: %{
      "host" => "",
      "port" => "587",
      "security" => "starttls",
      "from_address" => "",
      "from_name" => ""
    }

  @doc "Whether untested public values or submitted credentials differ from the saved identity."
  @spec dirty?(Changeset.t(), Settings.t() | nil, map()) :: boolean()
  def dirty?(%Changeset{} = changeset, settings, attrs) when is_map(attrs) do
    not changeset.valid? or values(changeset) != values(settings) or
      Enum.any?(["username", "password"], fn field ->
        case Map.get(attrs, field) do
          value when is_binary(value) -> String.trim(value) != ""
          nil -> false
          _invalid -> true
        end
      end)
  end

  defp text(nil), do: ""

  defp text(value) when is_binary(value) or is_integer(value) or is_atom(value),
    do: to_string(value)
end
