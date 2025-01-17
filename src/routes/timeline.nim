# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, strutils, sequtils, uri, options, times
import jester, karax/vdom

import router_utils
import ".."/[types, redis_cache, formatters, query, api]
import ../views/[general, profile, timeline, status, search]

export vdom
export uri, sequtils
export router_utils
export redis_cache, formatters, query, api
export profile, timeline, status

proc getQuery*(request: Request; tab, name: string): Query =
  case tab
  of "with_replies": getReplyQuery(name)
  of "media": getMediaQuery(name)
  of "search": initQuery(params(request), name=name)
  else: Query(fromUser: @[name])

proc fetchTimeline*(after: string; query: Query; skipRail=false):
                  Future[(Profile, Timeline, PhotoRail)] {.async.} =
  let name = query.fromUser[0]

  var
    profile: Profile
    profileId = await getProfileId(name)
    fetched = false

  if profileId.len == 0:
    profile = await getCachedProfile(name)
    profileId = profile.id
    fetched = true

  if profile.protected or profile.suspended:
    return (profile, Timeline(), @[])
  elif profileId.len == 0:
    return (Profile(username: name), Timeline(), @[])

  var rail: Future[PhotoRail]
  if skipRail or profile.protected or query.kind == media:
    rail = newFuture[PhotoRail]()
    rail.complete(@[])
  else:
    rail = getCachedPhotoRail(name)

  var timeline =
    case query.kind
    of posts: await getTimeline(profileId, after)
    of replies: await getTimeline(profileId, after, replies=true)
    of media: await getMediaTimeline(profileId, after)
    else: await getSearch[Tweet](query, after)

  timeline.query = query

  var found = false
  for tweet in timeline.content.mitems:
    if tweet.profile.id == profileId or
       tweet.profile.username.cmpIgnoreCase(name) == 0:
      profile = tweet.profile
      found = true
      break

  if profile.username.len == 0:
    profile = await getCachedProfile(name)
    fetched = true

  if fetched and not found:
    await cache(profile)

  return (profile, timeline, await rail)

proc showTimeline*(request: Request; query: Query; cfg: Config; prefs: Prefs;
                   rss, after: string): Future[string] {.async.} =
  if query.fromUser.len != 1:
    let
      timeline = await getSearch[Tweet](query, after)
      html = renderTweetSearch(timeline, prefs, getPath())
    return renderMain(html, request, cfg, prefs, "Multi", rss=rss)

  var (p, t, r) = await fetchTimeline(after, query)

  if p.suspended: return showError(getSuspended(p.username), cfg)
  if p.id.len == 0: return

  let pHtml = renderProfile(p, t, r, prefs, getPath())
  result = renderMain(pHtml, request, cfg, prefs, pageTitle(p), pageDesc(p),
                      rss=rss, images = @[p.getUserPic("_400x400")],
                      banner=p.banner)

template respTimeline*(timeline: typed) =
  let t = timeline
  if t.len == 0:
    resp Http404, showError("User \"" & @"name" & "\" not found", cfg)
  resp t

template respUserId*() =
  cond @"user_id".len > 0
  let username = await getCachedProfileUsername(@"user_id")
  if username.len > 0:
    redirect("/" & username)
  else:
    resp Http404, showError("User not found", cfg)

proc createTimelineRouter*(cfg: Config) =
  router timeline:
    get "/i/user/@user_id":
      respUserId()

    get "/intent/user":
      respUserId()

    get "/@name/?@tab?/?":
      cond '.' notin @"name"
      cond @"name" notin ["pic", "gif", "video"]
      cond @"tab" in ["with_replies", "media", "search", ""]
      let
        prefs = cookiePrefs()
        after = getCursor()
        names = getNames(@"name")

      var query = request.getQuery(@"tab", @"name")
      if names.len != 1:
        query.fromUser = names

      # used for the infinite scroll feature
      if @"scroll".len > 0:
        if query.fromUser.len != 1:
          var timeline = await getSearch[Tweet](query, after)
          if timeline.content.len == 0: resp Http404
          timeline.beginning = true
          resp $renderTweetSearch(timeline, prefs, getPath())
        else:
          var (_, timeline, _) = await fetchTimeline(after, query, skipRail=true)
          if timeline.content.len == 0: resp Http404
          timeline.beginning = true
          resp $renderTimelineTweets(timeline, prefs, getPath())

      let rss =
        if @"tab".len == 0:
          "/$1/rss" % @"name"
        elif @"tab" == "search":
          "/$1/search/rss?$2" % [@"name", genQueryUrl(query)]
        else:
          "/$1/$2/rss" % [@"name", @"tab"]

      respTimeline(await showTimeline(request, query, cfg, prefs, rss, after))
