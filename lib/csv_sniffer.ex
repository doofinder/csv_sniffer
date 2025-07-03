defmodule CsvSniffer do
  @moduledoc """
  An Elixir port of Python's
  [CSV Sniffer](https://github.com/python/cpython/blob/9bfb4a7061a3bc4fc5632bccfdf9ed61f62679f7/Lib/csv.py#L165-L448).
  """
  @moduledoc since: "0.1.0"

  alias CsvSniffer.Dialect

  @delimiters [",", "\t", ";", "|"]
  @delimiters_regex "[#{Enum.join(@delimiters, "")}]"

  @doc """
  "Sniffs" the format of a CSV sample (i.e. delimiter, quote character).

  Possible delimiters tried: `[",", ";", "|", "\t"]`

  ## Examples

      iex> \"""
      ...> Harry's,Arlington Heights,IL,2/1/03,Kimi Hayes
      ...> Shark City,Glendale Heights,IL,12/28/02,Prezence
      ...> Tommy's Place,Blue Island,IL,12/28/02,Blue Sunday/White Crow
      ...> Stonecutters Seafood and Chop House,Lemont,IL,12/19/02,Week Back
      ...> \"""
      ...> |> CsvSniffer.sniff()
      {:ok, %CsvSniffer.Dialect{
        delimiter: ",",
        quote_character: nil,
        double_quote: false
      }}

  """
  @doc since: "0.2.0"
  @spec sniff(sample :: String.t()) ::
          {:ok, Dialect.t()} | {:error, reason :: any()}
  def sniff(sample) when is_binary(sample) do
    sample
    |> guess_quote()
    |> guess_delimiter(sample)
    |> format_response()
  end

  @doc """
  The delimiter /should/ occur the same number of times on each row.  However, due to malformed
  data, it may not.  We don't want an all or nothing approach, so we allow for small variations
  in this number.
    1) build a table of the frequency of each character on every line.
    2) build a table of frequencies of this frequency (meta-frequency?), e.g. 'x occurred 5
       times in 10 rows, 6 times in 1000 rows, 7 times in 2 rows'
    3) use the mode of the meta-frequency to determine the /expected/ frequency for that character
    4) find out how often the character actually meets that goal
    5) the character that best meets its goal is the delimiter
  For performance reasons, the data is evaluated in chunks, so it can try and evaluate the
  smallest portion of the data possible, evaluating additional chunks as necessary.
  """
  @spec guess_delimiter(Dialect.t(), binary) :: Dialect.t()
  def guess_delimiter(%Dialect{delimiter: nil} = dialect, sample) do
    # inside this function, we can be sure there's no escape character ...
    newline = find_newline_character(sample)

    split_sample =
      sample
      |> String.split(newline)
      |> Stream.reject(&(String.trim(&1) == ""))

    initial_acc = %{frequency_tables: %{}, total: 0}

    delimiter =
      split_sample
      |> Stream.chunk_every(10)
      |> Enum.reduce_while(initial_acc, fn chunk,
                                           %{frequency_tables: frequency_tables, total: total} ->
        new_total = total + length(chunk)
        updated_frequency_tables = build_frequency_tables(chunk, frequency_tables)

        possible_delimiters =
          updated_frequency_tables
          |> get_mode_of_the_frequencies()
          |> build_a_list_of_possible_delimiters(new_total)
          |> Enum.filter(fn {k, _} -> Enum.member?(@delimiters, k) end)
          |> Enum.into(%{})

        cont_or_halt = if possible_delimiters == %{}, do: :cont, else: :halt

        {cont_or_halt,
         %{
           frequency_tables: updated_frequency_tables,
           possible_delimiters: possible_delimiters,
           total: new_total
         }}
      end)
      |> Map.get(:possible_delimiters)
      |> pick_delimiter()

    %Dialect{dialect | delimiter: delimiter}
  end

  @spec guess_delimiter(Dialect.t(), binary) :: Dialect.t()
  def guess_delimiter(dialect, _), do: dialect

  @doc """
  Looks for text enclosed between two identical quotes (the probable quotechar) which are
  preceded and followed by the same character (the probable delimiter).
  For example:
                   ,'some text',
  The quote with the most wins, same with the delimiter.  If there is no quotechar the delimiter
  can't be determined this way.
  """
  @spec guess_quote(binary) :: Dialect.t()
  def guess_quote(sample) do
    sample
    |> run_quote_regex()
    |> count_matches()
    |> pick_count_winners()
    |> check_double_quote(sample)
    |> check_quoted_delimiter(sample)
    |> check_quoted_carriage_return(sample)
    |> check_quoted_values(sample)
  end

  @spec quote_regex() :: [Regex.t()]
  defp quote_regex do
    [
      # ,".*?",
      ~r'(?P<delim>#{@delimiters_regex})(?P<quote>["\']).*?(?P=quote)(?P=delim)'sm,
      #  ".*?",
      ~r'(?:^|\n)(?P<quote>["\']).*?(?P=quote)(?P<delim>#{@delimiters_regex})'sm,
      # ,".*?"
      ~r'(?P<delim>#{@delimiters_regex})(?P<quote>["\']).*?(?P=quote)(?:$|\n)'sm,
      #  ".*?" (no delim)
      ~r'(?:^|\n)(?P<quote>["\']).*?(?P=quote)(?:$|\n)'sm
    ]
  end

  defp run_quote_regex(sample) do
    Enum.find_value(quote_regex(), {[], []}, fn regex ->
      names = Regex.names(regex)

      with matches <- Regex.scan(regex, sample, capture: :all_names),
           [_ | _] = matches <- Enum.filter(matches, &header_compatible?({names, &1}, sample)) do
        {names, matches}
      else
        _ -> false
      end
    end)
  end

  defp header_compatible?({["quote"], _}, _), do: true

  defp header_compatible?({["delim", "quote"], [delim_char, quote_char]}, sample) do
    quote_regex = ~r/^[^\n#{quote_char}]*#{quote_char}/

    case Regex.match?(quote_regex, sample) do
      false ->
        sample
        |> String.split("\n", parts: 2)
        |> List.first()
        |> get_best_delim_candidate()
        |> Kernel.==(delim_char)

      true ->
        true
    end
  end

  defp header_compatible?({["quote", "delim"], [q, d]}, sample),
    do: header_compatible?({["delim", "quote"], [d, q]}, sample)

  defp header_compatible?(_, _), do: false

  defp get_best_delim_candidate(line) do
    {candidate, _} =
      @delimiters
      |> Enum.map(fn delim ->
        freq =
          line
          |> String.split(delim)
          |> Kernel.length()

        {delim, freq}
      end)
      |> Enum.max(&(elem(&1, 1) > elem(&2, 1)))

    candidate
  end

  defp count_matches({names, matches}) do
    initial_acc = %{quote: %{}, delim: %{}}

    Enum.reduce(matches, initial_acc, fn match, acc ->
      names
      |> Enum.zip(match)
      |> reduce_zipped_matches(acc)
    end)
  end

  defp reduce_zipped_matches(zipped_matches, acc) do
    Enum.reduce(zipped_matches, acc, fn
      {"quote", value}, acc ->
        update_in(acc, [:quote, value], &((&1 || 0) + 1))

      {"delim", value}, acc ->
        update_in(acc, [:delim, value], &((&1 || 0) + 1))
    end)
  end

  defp pick_count_winners(%{quote: quotes, delim: delimiters}) do
    quote_character = max_by_value(quotes) || nil
    delimiter = max_by_value(delimiters)
    non_newline_delimiter = if delimiter == "\n", do: "", else: delimiter

    %Dialect{
      delimiter: non_newline_delimiter,
      quote_character: quote_character
    }
  end

  defp max_by_value(map) when map == %{}, do: nil

  defp max_by_value(map) do
    map
    |> Enum.max_by(&elem(&1, 1))
    |> elem(0)
  end

  defp check_double_quote(
         %Dialect{delimiter: delimiter, quote_character: quote_character} = dialect,
         sample
       )
       when is_binary(delimiter) and is_binary(quote_character) do
    escaped_delimiter = Regex.escape(delimiter)
    escaped_quote_character = Regex.escape(quote_character)

    # If we see an extra quote between delimiters, we've got a double quoted format.
    double_quote_regex =
      Regex.compile!(
        "((#{escaped_delimiter})|^)#{escaped_quote_character}" <>
          "([^#{escaped_quote_character}]*#{escaped_quote_character}{2})+[^#{escaped_quote_character}]*" <>
          "#{escaped_quote_character}((#{escaped_delimiter})|$)",
        "m"
      )

    if Regex.match?(double_quote_regex, sample) do
      %Dialect{dialect | quote_needed: true}
    else
      dialect
    end
  end

  defp check_double_quote(dialect, _), do: dialect

  defp check_quoted_delimiter(%{quote_needed: true} = dialect, _), do: dialect

  defp check_quoted_delimiter(%{quote_character: qc, delimiter: dl} = dialect, _)
       when is_nil(qc) or is_nil(dl) do
    dialect
  end

  defp check_quoted_delimiter(
         %Dialect{delimiter: delimiter, quote_character: quote_character} = dialect,
         sample
       ) do
    escaped_delimiter = Regex.escape(delimiter)
    escaped_quote_character = Regex.escape(quote_character)

    # If we see delimiter char within quotes, quotes are needed!
    # If we're here, there are no double quotes, no need to account for them in the regex
    quoted_delimiter_regex =
      Regex.compile!(
        "((#{escaped_delimiter})|^)#{escaped_quote_character}" <>
          "([^#{escaped_delimiter}#{escaped_quote_character}]*#{escaped_delimiter})+[^#{escaped_delimiter}#{escaped_quote_character}]*" <>
          "#{escaped_quote_character}((#{escaped_delimiter})|$)",
        "m"
      )

    if Regex.match?(quoted_delimiter_regex, sample) do
      %Dialect{dialect | quote_needed: true}
    else
      dialect
    end
  end

  defp check_quoted_carriage_return(%{quote_needed: true} = dialect, _), do: dialect

  defp check_quoted_carriage_return(%{quote_character: qc, delimiter: dl} = dialect, _)
       when is_nil(qc) or is_nil(dl) do
    dialect
  end

  defp check_quoted_carriage_return(
         %Dialect{delimiter: delimiter, quote_character: quote_character} = dialect,
         sample
       ) do
    escaped_delimiter = Regex.escape(delimiter)
    escaped_quote_character = Regex.escape(quote_character)

    # If we see \n within quotes, quotes are needed!
    # If we're here, there are no double quotes, no need to account for them in the regex
    quoted_carriage_return_regex =
      Regex.compile!(
        "((#{escaped_delimiter})|^)#{escaped_quote_character}" <>
          "([^\n#{escaped_quote_character}]*\n)+[^\n#{escaped_quote_character}]*" <>
          "#{escaped_quote_character}((#{escaped_delimiter})|$)",
        "m"
      )

    if Regex.match?(quoted_carriage_return_regex, sample) do
      %Dialect{dialect | quote_needed: true}
    else
      dialect
    end
  end

  # It can happen that theoretically there are no double quotes and no \n inside
  # quotes, but some field values are quoted-enclosed:
  # "some value","some other value","yep"
  # in that case, quote IS needed
  defp check_quoted_values(%{quote_needed: true} = dialect, _), do: dialect
  # we can count that NO quoted delimiter, and NO quoted newline are here
  defp check_quoted_values(%{quote_character: qc, delimiter: dl} = dialect, _)
       when is_nil(qc) or is_nil(dl),
       do: dialect

  defp check_quoted_values(%{delimiter: dl, quote_character: qc} = dialect, sample) do
    escaped_delimiter = Regex.escape(dl)
    escaped_quote_character = Regex.escape(qc)

    quoted_values_regex =
      Regex.compile!(
        "(#{escaped_delimiter}|^)#{escaped_quote_character}" <>
          "[^#{escaped_quote_character}]*#{escaped_quote_character}" <>
          "(#{escaped_delimiter}|$)",
        "m"
      )

    if Regex.match?(quoted_values_regex, sample),
      do: %Dialect{dialect | quote_needed: true},
      else: dialect
  end

  @seven_bit_ascii Enum.into(0..127, %{}, &{&1, 0})

  defp build_frequency_tables(data, acc) do
    data
    |> Stream.map(&to_charlist/1)
    |> Stream.map(fn line ->
      Enum.reduce(line, @seven_bit_ascii, &Map.update(&2, &1, 1, fn count -> count + 1 end))
    end)
    |> Enum.reduce(acc, &reduce_frequency_tables/2)
  end

  defp reduce_frequency_tables(frequency_table, acc) do
    Enum.reduce(frequency_table, acc, fn {character, frequency}, acc ->
      Map.update(acc, character, %{frequency => 1}, fn meta_frequency ->
        Map.update(meta_frequency, frequency, 1, &(&1 + 1))
      end)
    end)
  end

  defp get_mode_of_the_frequencies(frequency_tables) do
    Enum.reduce(frequency_tables, %{}, fn
      {_, %{0 => _} = items}, acc when map_size(items) == 1 ->
        acc

      # Limit to 7-bit ASCII characters
      {character, items}, acc when 0 <= character and character <= 127 ->
        {frequency, meta_frequency} = Enum.max_by(items, &elem(&1, 1))
        {_, remaining_items} = Map.pop(items, frequency)

        # adjust the mode - subtract the sum of all other frequencies
        adjusted_mode =
          {frequency, meta_frequency - (remaining_items |> Map.values() |> Enum.sum())}

        Map.put(acc, <<character>>, adjusted_mode)

      _, acc ->
        acc
    end)
  end

  @min_consistency_threshold 0.9

  defp build_a_list_of_possible_delimiters(modes, total, consistency \\ 1.0) do
    possible_delimiters =
      Enum.reduce(modes, %{}, fn
        {delimiter, {frequency, meta_frequency} = value}, acc
        when frequency > 0 and meta_frequency > 0 and meta_frequency / total >= consistency ->
          Map.put(acc, delimiter, value)

        _, acc ->
          acc
      end)

    if possible_delimiters == %{} and consistency > @min_consistency_threshold do
      build_a_list_of_possible_delimiters(modes, total, consistency - 0.01)
    else
      possible_delimiters
    end
  end

  defp pick_delimiter(possible_delimiters) when map_size(possible_delimiters) == 1 do
    possible_delimiters
    |> Map.keys()
    |> List.first()
  end

  defp pick_delimiter(possible_delimiters) when map_size(possible_delimiters) > 1,
    do: max_by_value(possible_delimiters)

  defp pick_delimiter(_), do: nil

  defp format_response(%{delimiter: nil}), do: {:error, "Could not determine delimiter"}

  defp format_response(%{delimiter: delimiter, quote_needed: false}),
    do: {:ok, %Dialect{delimiter: delimiter, quote_character: nil}}

  defp format_response(%{delimiter: delimiter, quote_character: quote_character}),
    do:
      {:ok, %Dialect{delimiter: delimiter, quote_character: quote_character, quote_needed: true}}

  defp find_newline_character(""), do: "\n"
  defp find_newline_character("\r\n" <> _), do: "\r\n"
  defp find_newline_character("\n" <> _), do: "\n"
  defp find_newline_character("\r" <> _), do: "\r"
  defp find_newline_character(<<_::utf8, rest::binary>>), do: find_newline_character(rest)
end
