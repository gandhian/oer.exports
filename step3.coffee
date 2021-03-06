system = require('system')
fs = require('fs')
page = require("webpage").create()

page.settings.localToRemoteUrlAccessEnabled = true
page.settings.ignoreSslErrors = true

page.onConsoleMessage = (msg, line, source) ->
  console.log "console> " + msg # + " @ line: " + line

if system.args.length < 3
  console.error "This program takes exactly 2 arguments:"
  console.error "The absolute path to this directory (I know, it's annoying but I need it to load the jquery, mathjax, and the like)"
  console.error "URL to the HTML file"
  console.error "URL to post the output (X)HTML file"
  console.error "URL to submit xincluded URLs to (and translate)"
  phantom.exit 1

programDir  = system.args[1]

inputUrl    = system.args[2]
outputUrl   = system.args[3]
depositUrl  = system.args[4]
LOCALHOST   = system.args[5]


page.onConsoleMessage = (message, url, lineNumber) ->
  console.error message


page.onError = (msg, trace) ->
  console.error(msg)
  trace.forEach (item) ->
    console.error('  ', item.file, ':', item.line);

  phantom.exit(1)

#if (!/^file:\/\/|http(s?):\/\//.test(appLocation)) {
#    appLocation = 'file:///' + fs.absolute(appLocation).replace(/\\/g, '/');
#}


console.error "Opening page at: #{inputUrl}"

page.onAlert = (msg) ->
  if msg
    phantom.exit(1)
  else
    console.error "All good, closing PhantomJS"
    phantom.exit(0)

page.open encodeURI(inputUrl), (status) ->
  if status != 'success'
    console.error "File not FOUND!!"
    phantom.exit(1)

  loadScript = (path) ->
    if page.injectJs(path)
    else
      console.error "Could not find #{path}"
      phantom.exit(1)
  
  loadScript(programDir + '/static/lib/jquery-latest.js')

  needToKeepWaiting = page.evaluate((outputUrl, depositUrl, LOCALHOST) ->

    loadScript = (src) ->
      $script = $('<script></script>')
      $script.attr('type', 'text/javascript')
      $script.attr('src', src)
      $('body').append $script

    loadScript "#{LOCALHOST}/lib/dom-to-xhtml.js"

    serializeHtml = (callback) ->
      # Hack to serialize out the HTML (sent to the console)
      console.log 'Serializing (X)HTML back out from WebKit...'
      $('script').remove()
      xhtmlAry = []
      xhtmlAry.push '<html xmlns="http://www.w3.org/1999/xhtml">'
      # Keep the base element in there
      xhtmlAry.push '<head>'
      window.dom2xhtml.serialize($('head meta')[0], xhtmlAry)
      xhtmlAry.push '</head>'
      window.dom2xhtml.serialize($('body')[0], xhtmlAry)
      xhtmlAry.push '</html>'

      console.log 'Submitting (X)HTML back to the server...'
      params =
        contents: xhtmlAry.join('')
      config =
        url: outputUrl
        type: 'POST'
        data : params
      $.ajax(config)
        .fail () ->
          alert "Submit Failed on POST to #{outputUrl}" # Problem.
        .done (text) ->
          console.log "Sent XHTML back to server with response: #{text}"
          alert '' # All OK to close up

    # Make URLs absolute instead of relative
    xincludes = $('a[href].xinclude')
    leftToProcess = xincludes.length

    if leftToProcess == 0
      serializeHtml()

    # Build up a mapping of http://cnx.org/content/m9003/latest/ -> [hashid]
    lookups = {}
    xincludes.each () ->
      $a = $(@)
      lookups[$a.attr('data-url')] = $a.attr('href')
    
    resolveId = (docId, $node, attrName) ->
      href = $node.attr(attrName)
      if href.charAt(0) == '#'
        href = '#' + "content-#{docId}-#{href.substring(1)}"
      else
        # It's an absolute URL. Try to look it up
        # ie "http://cnx.org/content/m9003/latest/#id123"
        [href, id] = href.split('#')
        if lookups[href]
          href = "content-#{lookups[href]}"
        if id
          href = href + '#' + id
      
      if $node.attr(attrName) != href
        console.log "Replacing [#{$node.attr(attrName)}] with [#{href}]"
      $node.attr(attrName, href)
    
    resolveIds = (docId, $el) ->
      $el.find('*[id]').each () ->
        $node = $(@)
        if not $node.parents('svg').length
          $node.attr('id', "content-#{docId}-#{$node.attr('id')}")

      $el.find('a[href]').each () ->
        $node = $(@)
        resolveId(docId, $node, 'href')
      
      $el.find('img[src]').each () ->
        $node = $(@)
        resolveId(docId, $node, 'src')
        
    
    xincludes.each () ->
      $a = $(@)
      href = $a.attr('href')
      
      # Include the file at this position (maybe put in the contents of the element)
      retries = 10
      tryAjax = () ->
        config =
          url: '/assembled/' + href
          type: 'GET'
          statusCode:
            200: (text) ->
              console.log "GET #{href} Succeeded. Injecting..."
              # jQuery('<html><head><meta/></head><body><div/></body></html>') strips out the html, head, and body tags
              # and just returns a litst of elements and text nodes "<meta/><div/>"
              newElements = $(text)
              
              resolveIds(href, newElements)
              parent = $a.parent()
              $a.replaceWith newElements
              
              if not $a.hasClass('autogenerated-label')
                $title = newElements.filter('.title').first()
                $title.contents().remove()
                $a.contents().appendTo $title
  
              leftToProcess--
              if leftToProcess == 0
                serializeHtml()

            202: () ->
              # Wait and repeat (depending on the status code)
              console.log "Retrying #{retries} GET #{href} in 30 seconds"
              if retries-- > 0
                setTimeout tryAjax, 30000
              else
                console.error "Gave up retrying to GET #{href}. Continuing on"
                leftToProcess--
                if leftToProcess == 0
                  serializeHtml()

        $.ajax(config)
          .fail () ->
            console.error "Failed for some reason other than still processing while calling GET #{config.url}"
      tryAjax()

  , outputUrl, depositUrl, LOCALHOST)