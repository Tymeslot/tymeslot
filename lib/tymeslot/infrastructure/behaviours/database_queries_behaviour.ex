defmodule Tymeslot.Infrastructure.DatabaseQueriesBehaviour do
  @moduledoc """
  A behaviour module defining the functions needed from DatabaseQueries.UserQueries.
  This behaviour allows applications to provide their own user query implementations.
  """

  # User creation and management
  @callback create_user(map()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  @callback update_user(term(), map()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  @callback delete_user(term()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}

  # User retrieval
  @callback get_user_by_email(String.t()) :: term() | nil
  @callback get_user(integer()) :: term() | nil
  @callback get_user_by_session_token(String.t()) :: term() | nil
  @callback get_user_by_verification_token(String.t()) :: term() | nil
  @callback get_user_by_reset_token(String.t()) :: term() | nil
  @callback get_user_by_github_id(integer()) :: term() | nil
  @callback get_user_by_google_id(String.t()) :: term() | nil

  # Token management
  @callback update_session_token(integer(), String.t(), DateTime.t()) :: {integer(), nil}
  @callback clear_session_token(integer()) :: {integer(), nil}
  @callback set_verification_token(term(), String.t()) ::
              {:ok, term()} | {:error, Ecto.Changeset.t()}
  @callback set_reset_token(term(), String.t()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}

  # Password management
  @callback update_password(term(), map()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
end
