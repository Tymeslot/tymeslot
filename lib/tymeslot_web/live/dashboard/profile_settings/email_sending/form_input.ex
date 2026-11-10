defmodule TymeslotWeb.Dashboard.ProfileSettings.EmailSending.FormInput do
  @moduledoc """
  Projects SMTP form input into public values without retaining credentials.

  The submitted credential fields are passed straight to the domain operation.
  Only public fields enter socket assigns or a rendered form value.
  An email-valued username can seed the new identity's public From address.
  """

  alias Ecto.Changeset
  alias Tymeslot.EmailSending.Settings
  alias Tymeslot.Security.FieldValidators.EmailValidator

  @public_fields [:host, :port, :security, :from_address, :from_name]
  @fields ~w(host security username password from_address from_name)

  @doc "The editable field names accepted by this form."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  Whitelists editable fields and derives the SMTP port from connection security.

  A submitted port is ignored on both validation and submission. Unsupported or
  missing security modes remain invalid instead of receiving a default mode.
  """
  @spec attributes(term()) :: map()
  def attributes(params) when is_map(params) do
    attrs = Map.take(params, @fields)

    case attrs["security"] do
      "implicit_tls" -> Map.put(attrs, "port", "465")
      "starttls" -> Map.put(attrs, "port", "587")
      _invalid -> attrs
    end
  end

  def attributes(_params), do: %{}

  @doc """
  Builds nonsecret form values, defaulting the display name only for a new identity.

  Saved and validated values remain authoritative, including an explicitly
  cleared display name. The profile default is used only before editing begins.
  """
  @spec values(Changeset.t() | Settings.t() | nil, String.t() | nil) ::
          %{String.t() => String.t()}
  def values(source, default_from_name \\ nil)

  def values(%Changeset{} = changeset, _default_from_name),
    do: Map.new(@public_fields, &{Atom.to_string(&1), text(Changeset.get_field(changeset, &1))})

  def values(%Settings{} = settings, _default_from_name),
    do: Map.new(@public_fields, &{Atom.to_string(&1), text(Map.fetch!(settings, &1))})

  def values(nil, default_from_name)
      when is_binary(default_from_name) or is_nil(default_from_name),
      do: %{
        "host" => "",
        "port" => "587",
        "security" => "starttls",
        "from_address" => "",
        "from_name" => default_from_name || ""
      }

  @doc """
  Suggests a From address using an email-valued SMTP username.

  Call only for a new identity before the owner edits the From address. Invalid
  and non-email usernames leave the suggestion blank; credentials themselves
  are neither changed nor returned as credential form values.
  """
  @spec default_from_address(map()) :: map()
  def default_from_address(attrs) when is_map(attrs) do
    username = Map.get(attrs, "username")

    address =
      if is_binary(username) and String.valid?(username) do
        candidate = String.trim(username)

        if byte_size(candidate) <= 254 and EmailValidator.validate(candidate) == :ok,
          do: candidate,
          else: ""
      else
        ""
      end

    Map.put(attrs, "from_address", address)
  end

  defp text(nil), do: ""

  defp text(value) when is_binary(value) or is_integer(value) or is_atom(value),
    do: to_string(value)
end
