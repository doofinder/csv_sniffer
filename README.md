# CsvSniffer - Fixed set of delimiters

An Elixir port of Python's
[CSV Sniffer](https://github.com/python/cpython/blob/9bfb4a7061a3bc4fc5632bccfdf9ed61f62679f7/Lib/csv.py#L165-L448), with a fixed set of delimiters: only considers `[";", ",", "|", "\t"]`

## Installation

The package can be installed by adding `csv_sniffer` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:csv_sniffer, "~> 0.2.0"}
  ]
end
```

Documentation can be found at [https://hexdocs.pm/csv_sniffer](https://hexdocs.pm/csv_sniffer).
