wrap = require 'co-express'
errors = require '../commons/errors'
database = require '../commons/database'
mongoose = require 'mongoose'
Promise = require 'bluebird'
Classroom = require '../models/Classroom'
LevelSession = require '../models/LevelSession'
Prepaid = require '../models/Prepaid'
TrialRequest = require '../models/TrialRequest'
User = require '../models/User'

cutoffDate = new Date(2015,11,11)
cutoffID = mongoose.Types.ObjectId(Math.floor(cutoffDate/1000).toString(16)+'0000000000000000')

module.exports =
  post: wrap (req, res) ->
    validTypes = ['course']
    unless req.body.type in validTypes
      throw new errors.UnprocessableEntity("type must be on of: #{validTypes}.")
      # TODO: deprecate or refactor other prepaid types

    if req.body.creator
      user = yield User.search(req.body.creator)
      if not user
        throw new errors.NotFound('User not found')
      req.body.creator = user.id

    prepaid = database.initDoc(req, Prepaid)
    database.assignBody(req, prepaid)
    prepaid.set('code', yield Prepaid.generateNewCodeAsync())
    prepaid.set('redeemers', [])
    database.validateDoc(prepaid)
    yield prepaid.save()
    res.status(201).send(prepaid.toObject())


  redeem: wrap (req, res) ->
    if not req.user?.isTeacher()
      throw new errors.Forbidden('Must be a teacher to use licenses')

    prepaid = yield database.getDocFromHandle(req, Prepaid)
    if not prepaid
      throw new errors.NotFound('Prepaid not found.')

    user = yield User.findById(req.body?.userID)
    if not user
      throw new errors.NotFound('User not found.')

    unless prepaid.get('creator').equals(req.user._id)
      throw new errors.Forbidden('You may not redeem licenses from this prepaid')
    unless prepaid.get('type') is 'course'
      throw new errors.Forbidden('This prepaid is not of type "course"')
    if user.isEnrolled()
      return res.status(200).send(prepaid.toObject({req: req}))

    yield prepaid.redeem(user)
      
    # return prepaid with new redeemer added locally
    redeemers = _.clone(prepaid.get('redeemers') or [])
    redeemers.push({ date: new Date(), userID: user._id })
    prepaid.set('redeemers', redeemers)
    res.status(201).send(prepaid.toObject({req: req}))

  fetchByCreator: wrap (req, res, next) ->
    creator = req.query.creator
    return next() if not creator

    unless req.user.isAdmin() or creator is req.user.id
      throw new errors.Forbidden('Must be logged in as given creator')
    unless database.isID(creator)
      throw new errors.UnprocessableEntity('Invalid creator')

    q = {
      _id: { $gt: cutoffID }
      creator: mongoose.Types.ObjectId(creator)
      type: 'course'
    }

    prepaids = yield Prepaid.find(q)
    res.send((prepaid.toObject({req: req}) for prepaid in prepaids))

  fetchActiveSchoolLicenses: wrap (req, res) ->
    unless req.user.isAdmin() or creator is req.user.id
      throw new errors.Forbidden('Must be logged in as given creator')
    licenseEndMonths = parseInt(req.query?.licenseEndMonths or 6)
    latestEndDate = new Date()
    latestEndDate.setUTCMonth(latestEndDate.getUTCMonth() + licenseEndMonths)
    query = {$and: [{type: 'course'}, {endDate: {$gt: new Date().toISOString()}}, {endDate: {$lt: latestEndDate.toISOString()}}, {$where: 'this.redeemers && this.redeemers.length > 0'}, {creator: {$exists: true}}]}
    # query.$and.push({creator: mongoose.Types.ObjectId('5553886d4366a784056d81eb')})
    prepaids = yield Prepaid.find(query, {creator: 1, startDate: 1, endDate: 1, maxRedeemers: 1, redeemers: 1}).lean()
    console.log new Date().toISOString(), 'prepaids', prepaids.length
    teacherIds = []
    teacherIds.push(prepaid.creator) for prepaid in prepaids
    teachers = yield User.find({_id: {$in: teacherIds}}, {_id: 1, permissions: 1, name: 1, emailLower: 1}).lean()
    adminMap = {}
    adminMap[teacher._id.toString()] = true for teacher in teachers when 'admin' in (teacher.permissions or [])
    # console.log 'admins found', Object.keys(adminMap).length
    teacherIds = _.reject(teacherIds, (id) -> adminMap[id.toString()])
    teachers = _.reject(teachers, (t) -> adminMap[t._id.toString()])
    studentPrepaidMap = {}
    for prepaid in prepaids when not adminMap[prepaid.creator.toString()]
      studentPrepaidMap[student.userID.toString()] = true for student in prepaid.redeemers or []
    console.log new Date().toISOString(), 'teacherIds', teacherIds.length
    console.log new Date().toISOString(), 'prepaids', prepaids.length
    console.log new Date().toISOString(), 'studentPrepaidMap', Object.keys(studentPrepaidMap).length

    # TODO: exclude more students that aren't in a classroom + have a license?
    classrooms = yield Classroom.find({ownerID: {$in: teacherIds}}, {name: 1, ownerID: 1, members: 1, courses: 1}).lean()
    levelOriginalStringsMap = {}
    for classroom in classrooms
      for course in classroom.courses
        for level in course.levels
          levelOriginalStringsMap[level.original.toString()] = true
    # LevelSession has a creator/level index, which isn't the same as creator/'level.original'
    levels = ({original, majorVersion: 0} for original of levelOriginalStringsMap)
    console.log new Date().toISOString(), 'classrooms', classrooms.length
    console.log new Date().toISOString(), 'levels', levels.length

    studentIds = []
    for classroom in classrooms
      for studentId in classroom.members when studentPrepaidMap[studentId.toString()]
        studentIds.push(studentId.toString())
    studentIds = _.uniq(studentIds)
    console.log new Date().toISOString(), 'students', studentIds.length

    # batchSize of 40-50 for 12mos seems to be the sweet spot for perf in dev env
    batchSize = Math.round(studentIds.length / 40);
    levelSessionPromises = []
    i = 0
    while i * batchSize < studentIds.length
      start = i * batchSize
      end = Math.min(i * batchSize + batchSize, studentIds.length)
      # console.log new Date().toISOString(), 'getting batch', i, start, end, studentIds.length
      levelSessionPromises.push(LevelSession.find({creator: {$in: studentIds.slice(start, end)}, level: {$in: levels}}, {changed: 1, creator: 1, 'state.complete': 1, 'level.original': 1}).lean())
      i++
    levelSessions = []
    Promise.all levelSessionPromises
    .then (results) =>
      console.log new Date().toISOString(), 'processing levelSessions..'
      levelSessions = results[0]
      for i in [1...results.length]
        for levelSession in results[i]
          levelSessions.push(levelSession)
      console.log new Date().toISOString(), 'levelSessions', levelSessions.length
      res.status(200).send({classrooms, levelSessions, prepaids, teachers})

  fetchActiveSchools: wrap (req, res) ->
    unless req.user.isAdmin() or creator is req.user.id
      throw new errors.Forbidden('Must be logged in as given creator')
    prepaids = yield Prepaid.find({type: 'course'}, {creator: 1, properties: 1, startDate: 1, endDate: 1, maxRedeemers: 1, redeemers: 1}).lean()
    userPrepaidsMap = {}
    today = new Date()
    userIDs = []
    redeemerIDs = []
    redeemerPrepaidMap = {}
    for prepaid in prepaids
      continue if new Date(prepaid.endDate ? prepaid.properties?.endDate ? '2000') < today
      continue if new Date(prepaid.endDate) < new Date(prepaid.startDate)
      userPrepaidsMap[prepaid.creator.valueOf()] ?= []
      userPrepaidsMap[prepaid.creator.valueOf()].push(prepaid)
      userIDs.push prepaid.creator
      for redeemer in prepaid.redeemers ? []
        redeemerIDs.push redeemer.userID + ""
        redeemerPrepaidMap[redeemer.userID + ""] = prepaid._id.valueOf()

    # Find recently created level sessions for redeemers
    lastMonth = new Date()
    lastMonth.setUTCDate(lastMonth.getUTCDate() - 30)
    levelSessions = yield LevelSession.find({$and: [{created: {$gte: lastMonth}}, {creator: {$in: redeemerIDs}}]}, {creator: 1}).lean()
    prepaidActivityMap = {}
    for levelSession in levelSessions
      prepaidActivityMap[redeemerPrepaidMap[levelSession.creator.valueOf()]] ?= 0
      prepaidActivityMap[redeemerPrepaidMap[levelSession.creator.valueOf()]]++

    trialRequests = yield TrialRequest.find({$and: [{type: 'course'}, {applicant: {$in: userIDs}}]}, {applicant: 1, properties: 1}).lean()
    schoolPrepaidsMap = {}
    for trialRequest in trialRequests
      school = trialRequest.properties?.nces_name ? trialRequest.properties?.organization ? trialRequest.properties?.school
      continue unless school
      if userPrepaidsMap[trialRequest.applicant.valueOf()]?.length > 0
        schoolPrepaidsMap[school] ?= []
        for prepaid in userPrepaidsMap[trialRequest.applicant.valueOf()]
          schoolPrepaidsMap[school].push prepaid

    res.send({prepaidActivityMap, schoolPrepaidsMap})
