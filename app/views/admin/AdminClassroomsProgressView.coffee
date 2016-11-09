utils = require 'core/utils'
RootView = require 'views/core/RootView'

# TODO: how do we surface classroom versioned levels that have seen been removed from latest courses?
# TODO: indicate potential courses and levels within furthest course
# TODO: adjust opacity of student on level cell based on num users
# TODO: better variables between current course/levels and classroom versioned ones
# TODO: exclude archived classes
# TODO: level cell widths based on level median playtime
# TODO: student in multiple classrooms with different programming languages

# TODO: refactor, cleanup, perf, yikes

# Outline:
# 1. Get a bunch of data
# 2. Get latest course and level maps
# 3. Get user activity and licenses
# 4. Get classroom activity
# 5. Build classroom progress

module.exports = class AdminClassroomsProgressView extends RootView
  id: 'admin-classrooms-progress-view'
  template: require 'templates/admin/admin-classrooms-progress'
  courseAcronymMap: utils.courseAcronyms

  initialize: ->
    return super() unless me.isAdmin()
    @licenseEndMonths = utils.getQueryVariable('licenseEndMonths', 6)
    @buildProgressData(@licenseEndMonths)
    super()

  buildProgressData: ->

    Promise.all [
      Promise.resolve($.get('/db/course')),
      Promise.resolve($.get('/db/campaign')),
      Promise.resolve($.get("/db/prepaid/-/active-school-licenses?licenseEndMonths=#{@licenseEndMonths}"))
    ]
    .then (results) =>
      [courses, campaigns, {@classrooms, levelSessions, prepaids, teachers}] = results
      courses = courses.filter((c) => c.releasePhase is 'released')
      utils.sortCourses(courses)
      licenses = prepaids.filter((p) => p.redeemers?.length > 0)
      licenses.sort (a, b) =>
        return -1 if a.endDate > b.endDate
        return 1 if b.endDate > a.endDate
        0

      # console.log 'courses', courses
      # console.log 'campaigns', campaigns
      # console.log 'classrooms', @classrooms
      # console.log 'licenses', licenses
      # console.log 'levelSessions', levelSessions

      @teacherMap = {}
      @teacherMap[teacher._id] = teacher for teacher in teachers
      # console.log '@teacherMap', @teacherMap

      [@courseLevelsMap, @originalSlugMap, orderedLevelOriginals] = @getLatestLevels(campaigns, courses)
      [userLatestActivityMap, userLevelOriginalCompleteMap, userLicensesMap] = @getUserActivity(levelSessions, licenses, orderedLevelOriginals)
      [classroomLicenseFurthestLevelMap, classroomLatestActivity, classroomLicenseCourseLevelMap] = @getClassroomActivity(@classrooms, @courseLevelsMap, userLatestActivityMap, userLicensesMap, userLevelOriginalCompleteMap)


      @classroomProgress = []
      for classroomId, licensesCourseLevelMap of classroomLicenseCourseLevelMap #when classroomId is '573ac4b48edc9c1f009cd6be'
        classroom = _.find(@classrooms, (c) -> c._id is classroomId)
        # console.log 'classroom', classroomId, classroom, @classrooms
        classroomLicenses = []
        for licenseId, courseLevelMap of licensesCourseLevelMap
          courseLastLevelIndexMap = {}
          courseLastLevelIndexes = []
          levels = []
          for courseId, levelMap of courseLevelMap
            for levelOriginal, val of levelMap
              levels.push({levelOriginal, numUsers: val})
            # console.log 'course last level', @courseLevelsMap[courseId].slug, @originalSlugMap[levelOriginal], levels.length - 1
            courseLastLevelIndexes.push({courseId, index: levels.length - 1})
            courseLastLevelIndexMap[courseId] = levels.length - 1
          license = _.find(licenses, (l) -> l._id is licenseId)
          furthestLevelIndex = levels.indexOf(_.findLast(levels, (l) -> l.numUsers > 0))
          percentComplete = (furthestLevelIndex + 1) / levels.length * 100
          courseLastLevelIndexes.sort((a, b) => utils.orderedCourseIDs.indexOf(a.courseId) - utils.orderedCourseIDs.indexOf(b.courseId))

          # TODO: is this stuff license-specific?
          # TODO: time to finally do missing levels
          # @courseLevelsMap latest course/levels: @courseLevelsMap[course._id] = {slug: course.slug, levels: []}
          # courseLevelMap current classroom course/levels: [course._id][level.original] ?= 0
          # Per-course missing levels in available courses
          missingCourses = [] # Totally missing courses
          for courseId, courseData of @courseLevelsMap #when @courseLevelsMap[courseId].slug is 'computer-science-3'
            if courseLevelMap[courseId]
              # console.log 'checking', @courseLevelsMap[courseId].slug
              # Look for levels past furthest
              # Where do we put them? Splice them into existing levels with extra missing=true field

              # This check only works for furthest course, not any after it
              # Identify course furthest is in
              # Have all classroom levels and furthest index for that
              # furthestLevelIndex > courseLastLevelIndexMap[courseId] means furthest level is after this course
              # furthestLevelIndex <= courseLastLevelIndexMap[courseId] means furthest level is at or before end of this course
              if furthestLevelIndex <= courseLastLevelIndexMap[courseId]
                currentCourseLevelOriginals = (levelOriginal for levelOriginal, val of courseLevelMap[courseId])
                latestCourseLevelOriginals = courseData.levels
                levelsXor = _.xor(currentCourseLevelOriginals, latestCourseLevelOriginals)
                # console.log 'levelsXor', @courseLevelsMap[courseId].slug, levelsXor
                latestMissingLevelOriginals = _.filter(levelsXor, (l) -> latestCourseLevelOriginals.indexOf(l) >= 0)
                # console.log 'latestMissingLevelOriginals', @courseLevelsMap[courseId].slug, _.map(latestMissingLevelOriginals, (l) => @originalSlugMap[l] or l)
                # Now need to exclude any levels before furthest student

                # Find latest insertion start index
                furthestCurrentIndex = currentCourseLevelOriginals.indexOf(classroomLicenseFurthestLevelMap[classroomId]?[licenseId])
                # console.log furthestCurrentIndex, classroomLicenseFurthestLevelMap[classroomId]?[licenseId], currentCourseLevelOriginals
                currentInsertionIndex = furthestCurrentIndex
                while currentInsertionIndex >= 0 and orderedLevelOriginals.indexOf(currentCourseLevelOriginals[currentInsertionIndex]) < 0
                  currentInsertionIndex--
                latestInsertionIndex = 0
                if currentInsertionIndex >= 0
                  latestInsertionIndex = orderedLevelOriginals.indexOf(currentCourseLevelOriginals[currentInsertionIndex]) + 1
                latestLevelsToAdd = _.filter(latestMissingLevelOriginals, (l) -> orderedLevelOriginals.indexOf(l) >= latestInsertionIndex and not _.find(levels, {levelOriginal: l}))
                latestLevelsToAdd.sort((a, b) => orderedLevelOriginals.indexOf(a) - orderedLevelOriginals.indexOf(b))
                # console.log 'latestLevelsToAdd', @courseLevelsMap[courseId].slug, furthestCurrentIndex, latestInsertionIndex, levels.length, _.map(latestLevelsToAdd, (l) => @originalSlugMap[l] or l)
                # Find spot for each latest level
                currentPreviousIndex = furthestCurrentIndex
                # console.log furthestCurrentIndex, @originalSlugMap[classroomLicenseFurthestLevelMap[classroomId]?[licenseId]], _.map(currentCourseLevelOriginals, (l) => @originalSlugMap[l] or l)
                for levelOriginal, i in latestLevelsToAdd #when @courseLevelsMap[courseId].slug is 'computer-science-4'
                  # Find spot to put new latest level
                  # Options:
                  # no furthest current, insert after prev
                  # furthest current is latest previous, then insert right after furthest
                  # latest previous is before furthest current, then insert right after furthest
                  # latest previous is not in current levels, then insert right after furthest
                  # latest previous is after furthest current, then insert after found latest previous

                  # previousLatestIndex = orderedLevelOriginals.indexOf(levelOriginal) - 1
                  previousLatestOriginal = orderedLevelOriginals[orderedLevelOriginals.indexOf(levelOriginal) - 1]
                  if currentPreviousIndex < 0
                    # no furthest current, insert at beginning
                    currentPreviousIndex = currentCourseLevelOriginals.indexOf(previousLatestOriginal)
                    if currentPreviousIndex < 0
                      currentPreviousIndex = 0
                      # console.log '# no furthest current or latest prev, insert at beginning', previousLatestOriginal, currentPreviousIndex, _.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}), @originalSlugMap[levelOriginal]
                      levels.splice(_.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}), 0, {levelOriginal, numusers: 0, missing: true})
                      currentCourseLevelOriginals.splice(currentPreviousIndex, 0, levelOriginal)
                    else
                      # console.log '# no furthest current, insert after latest prev', previousLatestOriginal, currentPreviousIndex, _.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}) + 1, @originalSlugMap[levelOriginal]
                      levels.splice(_.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}) + 1, 0, {levelOriginal, numusers: 0, missing: true})
                      currentCourseLevelOriginals.splice(currentPreviousIndex + 1, 0, levelOriginal)
                      currentPreviousIndex++

                  else if currentCourseLevelOriginals[currentPreviousIndex] is previousLatestOriginal or
                  currentCourseLevelOriginals.indexOf(previousLatestOriginal) < 0 or
                  currentCourseLevelOriginals.indexOf(previousLatestOriginal) < currentPreviousIndex
                    # furthest current is latest previous, then insert right after furthest
                    # latest previous is before furthest current, then insert right after furthest
                    # latest previous is not in current levels, then insert right after furthest
                    # console.log '# insert next to furthest', previousLatestOriginal, currentPreviousIndex, _.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}) + 1, @originalSlugMap[levelOriginal]
                    levels.splice(_.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}) + 1, 0, {levelOriginal, numusers: 0, missing: true})
                    currentCourseLevelOriginals.splice(currentPreviousIndex + 1, 0, levelOriginal)
                    currentPreviousIndex++

                  else #if currentCourseLevelOriginals.indexOf(previousLatestOriginal) > currentPreviousIndex
                    if currentCourseLevelOriginals.indexOf(previousLatestOriginal) <= currentPreviousIndex
                      console.log "ERROR! current index #{currentCourseLevelOriginals.indexOf(previousLatestOriginal)} of prev latest #{previousLatestOriginal} is <= currentPreviousIndex #{currentPreviousIndex}"
                    # latest previous is after furthest current, then insert after found latest previous
                    currentPreviousIndex = currentCourseLevelOriginals.indexOf(previousLatestOriginal)
                    # console.log '# no furthest current, insert at beginning', _.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}) + 1, @originalSlugMap[levelOriginal]
                    levels.splice(_.findIndex(levels, {levelOriginal: currentCourseLevelOriginals[currentPreviousIndex]}) + 1, 0, {levelOriginal, numusers: 0, missing: true})
                    currentCourseLevelOriginals.splice(currentPreviousIndex + 1, 0, levelOriginal)
                    currentPreviousIndex++

                  # Update courseLastLevelIndexes
                  for courseLastLevelIndexData in courseLastLevelIndexes
                    if utils.orderedCourseIDs.indexOf(courseLastLevelIndexData.courseId) >= utils.orderedCourseIDs.indexOf(courseId)
                      courseLastLevelIndexData.index++
                      # console.log 'incremented last level course index', courseLastLevelIndexData.index, @courseLevelsMap[courseLastLevelIndexData.courseId].slug, @originalSlugMap[levelOriginal]
                  # break if i >= 1
                # console.log 'levels', levels.length
            else
              missingCourses.push({courseId, levels: courseData.levels})
          classroomLicenses.push({courseLastLevelIndexes, license, levels, furthestLevelIndex, missingCourses, percentComplete})
          # console.log classroomId, licenseId, levels, levelMap
          # break
        @classroomProgress.push({classroom, licenses: classroomLicenses, latestActivity: classroomLatestActivity[classroom._id]})

      # Find least amount of content buffer by teacher
      # TODO: use classroom members instad of license redeemers?
      teacherContentBufferMap = {}
      for progress in @classroomProgress
        teacherId = progress.classroom.ownerID
        teacherContentBufferMap[teacherId] ?= {}
        percentComplete = _.max(_.map(progress.licenses, 'percentComplete'))
        if not teacherContentBufferMap[teacherId].percentComplete? or percentComplete > teacherContentBufferMap[teacherId].percentComplete
          teacherContentBufferMap[teacherId].percentComplete = percentComplete
        if not teacherContentBufferMap[teacherId].latestActivity? or progress.latestActivity > teacherContentBufferMap[teacherId].latestActivity
          teacherContentBufferMap[teacherId].latestActivity = progress.latestActivity
        numUsers = _.max(_.map(progress.licenses, (l) -> l.license?.redeemers?.length ? 0))
        if not teacherContentBufferMap[teacherId].numUsers? or numUsers > teacherContentBufferMap[teacherId].numUsers
          teacherContentBufferMap[teacherId].numUsers = numUsers
      # console.log 'teacherContentBufferMap', teacherContentBufferMap

      @classroomProgress.sort (a, b) ->
        idA = a.classroom.ownerID
        idB = b.classroom.ownerID
        if idA is idB
          percentCompleteA = _.max(_.map(a.licenses, 'percentComplete'))
          percentCompleteB = _.max(_.map(b.licenses, 'percentComplete'))
          if percentCompleteA > percentCompleteB
            return -1
          else if percentCompleteA < percentCompleteB
            return 1
          else
            latestActivityA = a.latestActivity
            latestActivityB = b.latestActivity
            if latestActivityA > latestActivityB
              return -1
            else if latestActivityA < latestActivityB
              return 1
            else
              numUsersA = _.max(_.map(a.licenses, (l) -> l.license?.redeemers?.length ? 0))
              numUsersB = _.max(_.map(b.licenses, (l) -> l.license?.redeemers?.length ? 0))
              if numUsersA > numUsersB
                return -1
              else if numUsersA < numUsersB
                return 1
              else
                return 0
        else
          percentCompleteA = teacherContentBufferMap[idA].percentComplete
          percentCompleteB = teacherContentBufferMap[idB].percentComplete
          if percentCompleteA > percentCompleteB
            return -1
          else if percentCompleteA < percentCompleteB
            return 1
          else
            latestActivityA = teacherContentBufferMap[idA].latestActivity
            latestActivityB = teacherContentBufferMap[idB].latestActivity
            if latestActivityA > latestActivityB
              return -1
            else if latestActivityA < latestActivityB
              return 1
            else
              numUsersA = teacherContentBufferMap[idA].numUsers
              numUsersB = teacherContentBufferMap[idB].numUsers
              if numUsersA > numUsersB
                return -1
              else if numUsersA < numUsersB
                return 1
              else
                return 0
      console.log 'classroomProgress', @classroomProgress

      @render?()

  getClassroomActivity: (classrooms, courseLevelsMap, userLatestActivityMap, userLicensesMap, userLevelOriginalCompleteMap) ->
    classroomLicenseFurthestLevelMap = {}
    classroomLatestActivity = {}
    classroomLicenseCourseLevelMap = {}
    for classroom in classrooms #when classroom._id is '573ac4b48edc9c1f009cd6be'
      for license in userLicensesMap[classroom.ownerID]
        licensedMembers = _.intersection(classroom.members, _.map(license.redeemers, 'userID'))
        # console.log 'classroom licensed members', classroom._id, license._id, licensedMembers
        continue if _.isEmpty(licensedMembers)
        classroomLicenseCourseLevelMap[classroom._id] ?= {}
        classroomLicenseCourseLevelMap[classroom._id][license._id] ?= {}
        courseOriginalLevels = []
        for course in utils.sortCourses(classroom.courses) when @courseLevelsMap[course._id]
          for level in course.levels
            courseOriginalLevels.push(level.original)
        userFurthestLevelOriginalMap = {}
        for userId, levelOriginalCompleteMap of userLevelOriginalCompleteMap when licensedMembers.indexOf(userId) >= 0
          userFurthestLevelOriginalMap[userId] ?= {}
          for levelOriginal, complete of levelOriginalCompleteMap
            if _.isEmpty(userFurthestLevelOriginalMap[userId]) or courseOriginalLevels.indexOf(levelOriginal) > courseOriginalLevels.indexOf(userFurthestLevelOriginalMap[userId])
              userFurthestLevelOriginalMap[userId] = levelOriginal
        # For each level, how many is that the furthest for?
        for course in utils.sortCourses(classroom.courses) when @courseLevelsMap[course._id]
          classroomLicenseCourseLevelMap[classroom._id][license._id][course._id] ?= {}
          for level in course.levels
            classroomLicenseCourseLevelMap[classroom._id][license._id][course._id][level.original] ?= 0
            for userId in licensedMembers
              # console.log 'furthest level checking', @courseLevelsMap[course._id].slug, @originalSlugMap[level.original], userId, @originalSlugMap[userFurthestLevelOriginalMap[userId]]
              # console.log 'furthest level for user', userId, @originalSlugMap[userFurthestLevelOriginalMap[userId]]
              if not classroomLatestActivity[classroom._id] or classroomLatestActivity[classroom._id] < userLatestActivityMap[userId]
                classroomLatestActivity[classroom._id] = userLatestActivityMap[userId]
              # if userLevelOriginalCompleteMap[userId][level.original]?
              if userFurthestLevelOriginalMap[userId] is level.original
                classroomLicenseCourseLevelMap[classroom._id][license._id][course._id][level.original]++
                classroomLicenseFurthestLevelMap[classroom._id] ?= {}
                classroomLicenseFurthestLevelMap[classroom._id][license._id] ?= {}
                classroomLicenseFurthestLevelMap[classroom._id][license._id] = level.original
                # console.log 'furthest level setting', @courseLevelsMap[course._id].slug, @originalSlugMap[level.original]
    # console.log 'classroomLicenseFurthestLevelMap', classroomLicenseFurthestLevelMap
    # console.log 'classroomLatestActivity', classroomLatestActivity
    # console.log 'classroomLicenseCourseLevelMap', classroomLicenseCourseLevelMap
    [classroomLicenseFurthestLevelMap, classroomLatestActivity, classroomLicenseCourseLevelMap]

  getLatestLevels: (campaigns, courses) ->
    courseLevelsMap = {}
    originalSlugMap = {}
    orderedLevelOriginals = []
    for course in courses
      campaign = _.find(campaigns, _id: course.campaignID)
      courseLevelsMap[course._id] = {slug: course.slug, levels: []}
      for levelOriginal, level of campaign.levels
        originalSlugMap[levelOriginal] = level.slug
        orderedLevelOriginals.push(levelOriginal)
        courseLevelsMap[course._id].levels.push(levelOriginal)
    # console.log 'orderedLevelOriginals', orderedLevelOriginals
    [courseLevelsMap, originalSlugMap, orderedLevelOriginals]

  getUserActivity: (levelSessions, licenses, orderedLevelOriginals) ->
    # TODO: need to do anything with level sessions not in latest classroom content?
    userLatestActivityMap = {}
    userLevelOriginalCompleteMap = {}
    for levelSession in levelSessions when orderedLevelOriginals.indexOf(levelSession?.level?.original) >= 0
      # unless orderedLevelOriginals.indexOf(levelSession?.level?.original) >= 0
      #   console.log 'skipping level session', levelSession
      #   continue
      userLevelOriginalCompleteMap[levelSession.creator] ?= {}
      userLevelOriginalCompleteMap[levelSession.creator][levelSession.level.original] = levelSession?.state?.complete ? false
      if not userLatestActivityMap[levelSession.creator] or userLatestActivityMap[levelSession.creator] < levelSession.changed
        userLatestActivityMap[levelSession.creator] = levelSession.changed
    # console.log 'userLatestActivityMap', userLatestActivityMap
    # console.log 'userLevelOriginalCompleteMap', userLevelOriginalCompleteMap

    userLicensesMap = {}
    for license in licenses
      userLicensesMap[license.creator] ?= []
      userLicensesMap[license.creator].push(license)
    # console.log 'userLicensesMap', userLicensesMap

    [userLatestActivityMap, userLevelOriginalCompleteMap, userLicensesMap]
