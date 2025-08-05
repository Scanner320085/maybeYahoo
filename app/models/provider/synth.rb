class Provider::Synth < Provider
  include ExchangeRateConcept, SecurityConcept

  Error = Class.new(Provider::Error)
  InvalidExchangeRateError = Class.new(Error)
  InvalidSecurityPriceError = Class.new(Error)

  def initialize(api_key)
    @api_key = api_key
  end

  def healthy?
    with_provider_response do
      json_string = '{"email": "dwight@example.com", "name": "Dwight Schrute","plan": "Free","api_calls_remaining": 970,"api_limit": 1000}'

      # JSON.parse(json_string).dig("email").present?
    end
  end

  def usage
    with_provider_response do
      json_string = '{"email": "dwight@example.com", "name": "Dwight Schrute","plan": "Free","api_calls_remaining": 970,"api_limit": 1000}'
      parsed = JSON.parse(json_string)

      remaining = parsed.dig("api_calls_remaining")
      limit = parsed.dig("api_limit")
      used = limit - remaining

      UsageData.new(
      used: used,
      limit: limit,
      utilization: used.to_f / limit * 100,
      plan: parsed.dig("plan"),
      )
    end
  end

  # ================================
  #          Exchange Rates
  # ================================

  def fetch_exchange_rate(from:, to:, date:)
    with_provider_response do
      query = BasicYahooFinance::Query.new
      pair = "#{from}#{to}=X"
      data = query.historical(pair, date, date)
      data = data[0]
      Rails.logger.warn("[ExchangeRate] Data brut pour #{pair} au #{date}: #{data.inspect}")

      dates = data.dig("timestamp").map { |d| Time.at(d) }
      prices = data.dig("indicators", "quote")
      prices = prices[0].dig("close")

      entryDate = dates.first
      entryPrice = prices.first
      raise InvalidExchangeRateError, "No rate for #{pair} on #{date}" unless entryDate && entryPrice

      dates.zip(prices).map do |date, price|
        Rate.new(date: entryDate, from:, to:, rate: entryPrice)
      end
    end
  end

  def fetch_exchange_rates(from:, to:, start_date:, end_date:)
    with_provider_response do
      query = BasicYahooFinance::Query.new
      pair = "#{from}#{to}=X"
      start_date = start_date.to_s
      end_date = end_date.to_s
      data = query.historical(pair, start_date, end_date)
      data = data[0]

      dates = data.dig("timestamp").map { |d| Date.parse(Time.at(d).strftime("%Y-%m-%d")) }
      rates = data.dig("indicators", "quote")
      rates = rates[0].dig("close")

      dates.zip(rates).map do |date, rate|
        if date.nil? || rate.nil?
          Rails.logger.warn("#{self.class.name} returned invalid rate data for pair from: #{from} to: #{to} on: #{date}.  Rate data: #{rate.inspect}")
          Sentry.capture_exception(InvalidExchangeRateError.new("#{self.class.name} returned invalid rate data"), level: :warning) do |scope|
            scope.set_context("rate", { from: from, to: to, date: date })
          end

          next
        end

        Rate.new(date: date, from:, to:, rate: rate)
      end.compact
    end
  end

  # ================================
  #           Securities
  # ================================

  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      query = BasicYahooFinance::Query.new

      data = query.search(symbol)

      # Yahoo Finance retourne un tableau sous :quotes
      results = data.map do |security|
        # retrievedSymbol = security.dig("symbol")
        country_code = query.quotes(security.dig("symbol"))
        country_code = country_code.dig(security.dig("symbol"))
        country_code = country_code.dig("region")
        Security.new(
          symbol: security.dig("symbol"),
          name: security.dig("shortname") || security.dig("longname") || security.dig("name"),
          logo_url: "https://logo.synthfinance.com/#{security.dig("symbol")}", # Yahoo ne fournit pas de logo dans la recherche
          exchange_operating_mic: security.dig("exchDisp"), # c’est le nom affiché, pas un MIC strict
          country_code: country_code # Yahoo ne fournit pas de code pays dans la recherche
          )
      end
      results
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic: nil)
    with_provider_response do
      query = BasicYahooFinance::Query.new
      data = query.quote(symbol)
      data = data[symbol]

      SecurityInfo.new(
      symbol: symbol,
      name: data[:longName],
      links: {},
      logo_url: nil,
      description: data[:longBusinessSummary],
      kind: data[:quoteType],
      exchange_operating_mic: data[:exchange]
      )
    end
  end

  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    response = fetch_security_prices(
      symbol: symbol,
      exchange_operating_mic: exchange_operating_mic,
      start_date: date,
      end_date: date
    )

    return Provider::Response.new(success?: false, error: response.error) unless response.success?

    price = response.data.find { |p| p.date.to_date == date.to_date }

    if price
      Provider::Response.new(success?: true, data: price, error: nil)
    else
      Provider::Response.new(success?: false, data: nil, error: Provider::Synth::Error.new("No price found on #{date}"))
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    if start_date == end_date
      end_date += 1.day
    end
    with_provider_response do
      query = BasicYahooFinance::Query.new
      start_date = start_date.to_s
      end_date = end_date.to_s
      data = query.historical(symbol, start_date, end_date)
      data = data[0]

      currency = data.dig("meta", "currency")
      exchange_operating_mic = data.dig("meta", "exchangeName")
      symbolGet = data.dig("meta", "symbol")

      dates = data.dig("timestamp").map { |d| Date.parse(Time.at(d).strftime("%Y-%m-%d")) }
      prices = data.dig("indicators", "quote")
      prices = prices[0].dig("close") || prices[0].dig("open")

      if dates.nil? || prices.nil?
        Rails.logger.warn("#{self.class.name}    #{symbol} on: #{date}.  Price data: #{price.inspect}")
        Sentry.capture_exception(InvalidSecurityPriceError.new("#{self.class.name} returned invalid security price data"), level: :warning) do |scope|
          scope.set_context("security", { symbol: symbol, date: date })
        end

        next
      end

      dates.zip(prices).map do |date, price|
        Price.new(
            symbol: symbolGet,
            date: date,
            price: price,
            currency: currency,
            exchange_operating_mic: exchange_operating_mic
        )
      end.compact
    end
  end
end
