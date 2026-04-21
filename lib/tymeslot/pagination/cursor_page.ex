defmodule Tymeslot.Pagination.CursorPage do
  @moduledoc """
  Generic cursor page response for keyset pagination.

  Cursors are signed with `Phoenix.Token` using the endpoint's
  `secret_key_base`. An unsigned or tampered cursor fails verification and
  decodes to `{:error, :invalid_cursor}`, preventing attackers from forging
  an `after_id` to probe another user's row ordering.

  Cursors are intentionally permanent (`max_age: :infinity`): they represent
  bookmarkable pagination state and must remain valid across server restarts
  and indefinitely long-lived browser sessions. Both `encode_cursor/1` and
  `decode_cursor/1` pass `max_age: :infinity` explicitly so the intent is
  auditable at both call sites.
  """

  alias Phoenix.Token
  alias TymeslotWeb.Endpoint

  @enforce_keys [:items]
  defstruct items: [], next_cursor: nil, prev_cursor: nil, page_size: nil, has_more: false

  @type t(item) :: %__MODULE__{
          items: [item],
          next_cursor: String.t() | nil,
          prev_cursor: String.t() | nil,
          page_size: pos_integer() | nil,
          has_more: boolean()
        }
  @type t :: t(map())

  # Bump the salt when the cursor payload shape changes; it also invalidates
  # every cursor currently in the wild.
  @salt "cursor-page:v1"

  @doc """
  Encodes a cursor map like %{after_start: DateTime.t(), after_id: binary()} to a signed URL-safe string.
  """
  @spec encode_cursor(%{after_start: DateTime.t(), after_id: binary()}) :: String.t()
  def encode_cursor(%{after_start: %DateTime{} = after_start, after_id: after_id})
      when is_binary(after_id) do
    Token.sign(Endpoint, @salt, %{after_start: after_start, after_id: after_id},
      max_age: :infinity
    )
  end

  @doc """
  Decodes a signed cursor string back into a map.
  Returns `{:ok, map}` only if the signature verifies against the endpoint's
  `secret_key_base`; otherwise `{:error, :invalid_cursor}`.
  """
  @spec decode_cursor(String.t()) ::
          {:ok, %{after_start: DateTime.t(), after_id: binary()}} | {:error, :invalid_cursor}
  def decode_cursor(cursor) when is_binary(cursor) do
    case Token.verify(Endpoint, @salt, cursor, max_age: :infinity) do
      {:ok, %{after_start: %DateTime{} = after_start, after_id: after_id}}
      when is_binary(after_id) ->
        {:ok, %{after_start: after_start, after_id: after_id}}

      _invalid ->
        {:error, :invalid_cursor}
    end
  end
end
