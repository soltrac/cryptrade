_ = require 'underscore'
logger = require 'winston'
vm = require 'vm'
Fiber = require 'fibers'
inspect = require('./utils').inspect
Instrument = require './instrument'
talib = require './talib_sync'

class Trader
  constructor: (@name,@config,@account,@script)->
    @sandbox = 
      _:_
      talib: talib
      portfolio: 
        positions: {}
      debug: (message)->
        logger.verbose message
      info: (message)->
        logger.info message
      warn: (message)->
        logger.info message
      buy: (instrument,amount,price,timeout)=>
        @trade
          asset: instrument.asset()
          curr: instrument.curr()
          platform: instrument.platform
          type: 'buy'
          amount: amount
          price: price
          timeout: timeout
      sell: (instrument,amount,price,timeout)=>
        @trade
          asset: instrument.asset()
          curr: instrument.curr()
          platform: instrument.platform
          type: 'sell'
          amount: amount
          price: price
          timeout: timeout
      plot: (series)->
        # do nothing
      sendEmail: (text)->
        logger.verbose 'Sending e-mail '+text
        # @TODO add send email functionality
    @script = vm.runInNewContext @script, @sandbox, @name
    _.extend @sandbox,@script
    platformCls = require('./platforms/'+config.platform)
    platform = new platformCls()
    try
      platform.init config.platforms[config.platform],config.instrument,@account
    catch e
      logger.error e.message
      process.exit 1
    @data = {}
    instrument = new Instrument(platform,@config.instrument)
    @data[config.instrument] = instrument
    @data.instruments = [instrument]
    @context = {}
    @sandbox.init @context

  updateTicker: (platform,cb)->
    platform.getTicker (err,ticker)=>
      if err?
        logger.error err
      else
        logger.verbose "updateTicker: #{inspect(ticker)}"
        @ticker = ticker
        cb()

  updatePortfolio: (positions,platform,cb)->
    platform.getPositions positions,(err, result)=>
      if err?
        logger.error err
      else
        logger.verbose "updatePortfolio: #{inspect(result)}"
        for curr,amount of result
          @sandbox.portfolio.positions[curr] =
            amount:amount
        cb()

  calcPositions: (pair)->
    asset = pair[0]
    curr = pair[1]
    amount = @sandbox.portfolio.positions[asset].amount
    result = "#{amount} #{asset.toUpperCase()} "
    if @ticker?
      result += "(#{amount*@ticker.sell} #{curr.toUpperCase()}) "
    cash = @sandbox.portfolio.positions[curr].amount
    result += "#{cash} #{curr.toUpperCase()}"
    result

  trade: (order)->
    platform = order.platform
    switch order.type
      when 'buy'
        order.price = order.price or @ticker.buy
        order.priceTicker = @ticker.buy
        order.maxAmount = order.amount or @sandbox.portfolio.positions[order.curr].amount / order.price
        break
      when 'sell'
        order.price = order.price or @ticker.sell
        order.priceTicker = @ticker.sell
        order.maxAmount = order.amount or @sandbox.portfolio.positions[order.asset].amount
        break
    platform.trade order, (err,orderId)=>
      if err?
        logger.info err
        return
      self = @
      if orderId
        orderStr = "##{orderId} "
      else
        orderStr = '' 
      orderCb = ->
        self.updatePortfolio [order.asset,order.curr], order.platform,(err)=>
          unless err?
            balance = self.calcPositions [order.asset,order.curr]
            message = "#{order.type.toUpperCase()} order #{orderStr}traded. Balance: #{balance}"
            self.sandbox.info message
      if orderId
        switch order.type
          when 'buy'
            amount = order.amount or @sandbox.portfolio.positions[order.curr].amount / order.price
            logger.info "BUY order ##{orderId} amount: #{amount} #{order.asset.toUpperCase()} @ #{order.price}"
            break
          when 'sell'
            amount = order.amount or @sandbox.portfolio.positions[order.asset].amount
            logger.info "SELL order ##{orderId} amount: #{amount} #{order.asset.toUpperCase()} @ #{order.price}"
            break
        timeout = order.timeout or @config.check_order_interval
        setTimeout =>
          platform.isOrderActive orderId,(err,active)=>
            if err?
              logger.error err
            if active
              logger.info "Canceling order ##{orderId} as it was inactive for #{timeout} seconds."
              platform.cancelOrder orderId, (err)=>
                if err?
                  logger.error err
            else
              orderCb()
        ,timeout*1000
      else
        orderCb()

  init: (bars)->
    instrument = @data[@config.instrument]
    for bar in bars
      instrument.update bar
    @updatePortfolio instrument.pair,instrument.platform, =>
      balance = @calcPositions instrument.pair
      logger.info "Trader initialized successfully. Starting balance: #{balance}"

  handle: (bar)->
    instrument = @data[bar.instrument]
    instrument.update bar
    @data.at = bar.at
    @updateTicker instrument.platform, =>
      @updatePortfolio instrument.pair,instrument.platform, =>
        Fiber =>
          @sandbox.handle @context, @data
        .run()
    
module.exports = Trader
