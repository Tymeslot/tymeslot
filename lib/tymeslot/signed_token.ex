defmodule Tymeslot.SignedToken do
  @moduledoc """
  Every `Phoenix.Token` the application signs, by purpose.

  Each purpose has its own salt, so a token signed for one can never verify
  as another, and its own lifetime. The salts are what tokens already handed
  out were signed with: changing one invalidates every token of that purpose
  in the wild (an approval link in an inbox, an embed session in a page), so
  change a salt only to do exactly that.
  """

  alias Phoenix.Token
  alias TymeslotWeb.Endpoint

  @type purpose ::
          :embed_session
          | :meeting_approval
          | :oauth_signup_confirmation
          | :booking_preview
          | :cursor_page
          | :slack_oauth_state

  @purposes %{
    embed_session: [salt: "embed_session", max_age: 6 * 3600],
    # Two weeks is the longest window a meeting type may configure; the extra
    # fortnight covers a host coming back from leave to a request that has
    # long since lapsed, so they see "this expired" rather than a broken link.
    meeting_approval: [salt: "meeting approval", max_age: 28 * 24 * 3600],
    oauth_signup_confirmation: [
      salt: "oauth typed-email sign-up confirmation",
      max_age: 24 * 3600
    ],
    booking_preview: [salt: "booking owner preview", max_age: 3600],
    # Cursors are permanent: they name a position, not a grant. Bump the
    # salt when the cursor payload shape changes; that also invalidates every
    # cursor in the wild.
    cursor_page: [salt: "cursor-page:v1", max_age: :infinity],
    # Ten minutes to finish the Slack install it was issued for.
    slack_oauth_state: [salt: "slack_oauth_state", max_age: 600]
  }

  @doc "Signs `payload` for `purpose`."
  @spec sign(purpose(), term()) :: String.t()
  def sign(purpose, payload) do
    entry = Map.fetch!(@purposes, purpose)
    Token.sign(Endpoint, entry[:salt], payload, max_age: entry[:max_age])
  end

  @doc """
  Verifies a token signed for `purpose` and, when given, checks its payload.

  Options:

    * `:max_age` - overrides the purpose's lifetime, in seconds.
    * `:validate` - a function the payload must pass, returning
      `{:ok, value}` or `{:error, reason}`; the default accepts any payload.

  Returns `{:ok, value}`, or `{:error, reason}` for a token that is
  tampered with, signed for another purpose, expired or rejected.
  """
  @spec verify(purpose(), String.t(), keyword()) :: {:ok, term()} | {:error, atom()}
  def verify(purpose, token, opts \\ []) when is_binary(token) do
    entry = Map.fetch!(@purposes, purpose)
    max_age = Keyword.get(opts, :max_age, entry[:max_age])
    validate = Keyword.get(opts, :validate, &{:ok, &1})

    case Token.verify(Endpoint, entry[:salt], token, max_age: max_age) do
      {:ok, value} -> validate.(value)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "How long a token signed for `purpose` stays valid, in seconds."
  @spec max_age(purpose()) :: pos_integer() | :infinity
  def max_age(purpose), do: @purposes |> Map.fetch!(purpose) |> Keyword.fetch!(:max_age)
end
