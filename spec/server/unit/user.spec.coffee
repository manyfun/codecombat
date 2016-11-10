GLOBAL._ = require 'lodash'

User = require '../../../server/models/User'
utils = require '../utils'
mongoose = require 'mongoose'

describe 'User', ->

  it 'uses the schema defaults to fill in email preferences', (done) ->
    user = new User()
    expect(user.isEmailSubscriptionEnabled('generalNews')).toBeTruthy()
    expect(user.isEmailSubscriptionEnabled('anyNotes')).toBeTruthy()
    expect(user.isEmailSubscriptionEnabled('recruitNotes')).toBeTruthy()
    expect(user.isEmailSubscriptionEnabled('archmageNews')).toBeFalsy()
    done()
  
  it 'uses old subs if they\'re around', (done) ->
    user = new User()
    user.set 'emailSubscriptions', ['tester']
    expect(user.isEmailSubscriptionEnabled('adventurerNews')).toBeTruthy()
    expect(user.isEmailSubscriptionEnabled('generalNews')).toBeFalsy()
    done()

  it 'maintains the old subs list if it\'s around', (done) ->
    user = new User()
    user.set 'emailSubscriptions', ['tester']
    user.setEmailSubscription('artisanNews', true)
    expect(JSON.stringify(user.get('emailSubscriptions'))).toBe(JSON.stringify(['tester', 'level_creator']))
    done()
    
  it 'does not allow anonymous to be set to true if there is a login method', utils.wrap (done) ->
    user = new User({passwordHash: '1234', anonymous: true})
    user = yield user.save()
    expect(user.get('anonymous')).toBe(false)
    done()

  it 'prevents duplicate oAuthIdentities', utils.wrap (done) ->
    provider1 = new mongoose.Types.ObjectId()
    provider2 = new mongoose.Types.ObjectId()
    identity1 = { provider: provider1, id: 'abcd' }
    identity2 = { provider: provider2, id: 'abcd' }
    identity3 = { provider: provider1, id: '1234' }

    # These three should live in harmony
    users = []
    users.push yield utils.initUser({ oAuthIdentities: [identity1] })
    users.push yield utils.initUser({ oAuthIdentities: [identity2] })
    users.push yield utils.initUser({ oAuthIdentities: [identity3] })

    e = null
    try
      users.push yield utils.initUser({ oAuthIdentities: [identity1] })
    catch e

    expect(e).not.toBe(null)
    done()

  describe '.updateServiceSettings()', ->
    makeMC = (callback) ->

    it 'uses emails to determine what to send to MailChimp', ->
      user = new User({emailSubscriptions: ['announcement'], email: 'tester@gmail.com'})
      spyOn(user, 'updateMailChimp').and.returnValue(Promise.resolve())
      User.updateServiceSettings(user)
      expect(user.updateMailChimp).toHaveBeenCalled()

  describe '.isAdmin()', ->
    it 'returns true if user has "admin" permission', (done) ->
      adminUser = new User()
      adminUser.set('permissions', ['whatever', 'admin', 'user'])
      expect(adminUser.isAdmin()).toBeTruthy()
      done()

    it 'returns false if user has no permissions', (done) ->
      myUser = new User()
      myUser.set('permissions', [])
      expect(myUser.isAdmin()).toBeFalsy()
      done()
  
    it 'returns false if user has other permissions', (done) ->
      classicUser = new User()
      classicUser.set('permissions', ['user'])
      expect(classicUser.isAdmin()).toBeFalsy()
      done()
  
  describe '.verificationCode(timestamp)', ->
    it 'returns a timestamp and a hash', (done) ->
      user = new User()
      now = new Date()
      code = user.verificationCode(now.getTime())
      expect(code).toMatch(/[0-9]{13}:[0-9a-f]{64}/)
      [timestamp, hash] = code.split(':')
      expect(new Date(parseInt(timestamp))).toEqual(now)
      done()
      
  describe '.incrementStatAsync()', ->
    it 'records nested stats', utils.wrap (done) ->
      user = yield utils.initUser()
      yield User.incrementStatAsync user.id, 'stats.testNumber'
      yield User.incrementStatAsync user.id, 'stats.concepts.basic', {inc: 10}
      user = yield User.findById(user.id)
      expect(user.get('stats.testNumber')).toBe(1)
      expect(user.get('stats.concepts.basic')).toBe(10)
      done()
      
  describe 'subscription virtual', ->
    it 'has active and ends properties', ->
      moment = require 'moment'
      stripeEnd = moment().add(12, 'months').toISOString().substring(0,10)
      user1 = new User({stripe: {free:stripeEnd}})
      expectedEnd = "#{stripeEnd}T00:00:00.000Z"
      expect(user1.get('subscription').active).toBe(true)
      expect(user1.get('subscription').ends).toBe(expectedEnd)
      expect(user1.toObject({virtuals: true}).subscription.ends).toBe(expectedEnd)
      
      user2 = new User()
      expect(user2.get('subscription').active).toBe(false)
      
      user3 = new User({stripe: {free: true}})
      expect(user3.get('subscription').active).toBe(true)
      expect(user3.get('subscription').ends).toBeUndefined()

  describe '.updateMailChimp()', ->
    mailChimp = require '../../../server/lib/mail-chimp'

    it 'propagates user notification and name settings to MailChimp', utils.wrap (done) ->
      user = yield utils.initUser({
        emailVerified: true
        firstName: 'First'
        lastName: 'Last'
        emails: {
          diplomatNews: { enabled: true }
        }
      })
      spyOn(mailChimp.api, 'put').and.returnValue(Promise.resolve())
      yield user.updateMailChimp()
      expect(mailChimp.api.put.calls.count()).toBe(1)
      args = mailChimp.api.put.calls.argsFor(0)
      expect(args[0]).toMatch("^/lists/[0-9a-f]+/members/[0-9a-f]+$")
      expect(args[1].email_address).toBe(user.get('email'))
      diplomatInterest = _.find(mailChimp.interests, (interest) -> interest.property is 'diplomatNews')
      for [key, value] in _.pairs(args[1].interests)
        if key is diplomatInterest.mailChimpId
          expect(value).toBe(true)
        else
          expect(value).toBe(false)
      expect(args[1].status).toBe('subscribed')
      expect(args[1].merge_fields['FNAME']).toBe('First')
      expect(args[1].merge_fields['LNAME']).toBe('Last')
      user = yield User.findById(user.id)
      expect(user.get('mailChimp').email).toBe(user.get('email'))
      done()
      
    describe 'when user email is validated on MailChimp but not CodeCombat', ->
      
      it 'still updates their settings on MailChimp', utils.wrap (done) ->
        email = 'some@email.com'
        user = yield utils.initUser({
          email
          emailVerified: false
          emails: {
            diplomatNews: { enabled: true }
          }
          mailChimp: { email }
        })
        spyOn(mailChimp.api, 'get').and.returnValue(Promise.resolve({ status: 'subscribed' }))
        spyOn(mailChimp.api, 'put').and.returnValue(Promise.resolve())
        yield user.updateMailChimp()
        expect(mailChimp.api.get.calls.count()).toBe(1)
        expect(mailChimp.api.put.calls.count()).toBe(1)
        args = mailChimp.api.put.calls.argsFor(0)
        expect(args[1].status).toBe('subscribed')
        done()
        
    describe 'when the user\'s email changes', ->
      
      it 'unsubscribes the old entry, and does not subscribe the new email until validated', utils.wrap (done) ->
        oldEmail = 'old@email.com'
        newEmail = 'new@email.com'
        user = yield utils.initUser({
          email: newEmail
          emailVerified: false
          emails: {
            diplomatNews: { enabled: true }
          }
          mailChimp: { email: oldEmail }
        })
        spyOn(mailChimp.api, 'put').and.returnValue(Promise.resolve())
        yield user.updateMailChimp()
        expect(mailChimp.api.put.calls.count()).toBe(1)
        args = mailChimp.api.put.calls.argsFor(0)
        expect(args[1].status).toBe('unsubscribed')
        expect(args[0]).toBe(mailChimp.makeSubscriberUrl(oldEmail))
        done()
      
    describe 'when the user is not subscribed on MailChimp and is not subscribed to any interests on CodeCombat', ->
      
      it 'does nothing', utils.wrap (done) ->
        user = yield utils.initUser({
          emailVerified: true
          emails: {
            
          }
        })
        spyOn(mailChimp.api, 'get')
        spyOn(mailChimp.api, 'put')
        yield user.updateMailChimp()
        expect(mailChimp.api.get.calls.count()).toBe(0)
        expect(mailChimp.api.put.calls.count()).toBe(0)
        done()
      
    describe 'when the user is on MailChimp but not validated there nor on CodeCombat', ->
      
      it 'updates with status set to unsubscribed', ->
        email = 'some@email.com'
        user = yield utils.initUser({
          email
          emailVerified: false
          emails: {
            diplomatNews: { enabled: true }
          }
          mailChimp: { email }
        })
        spyOn(mailChimp.api, 'get').and.returnValue(Promise.resolve({ status: 'subscribed' }))
        spyOn(mailChimp.api, 'put').and.returnValue(Promise.resolve())
        yield user.updateMailChimp()
        expect(mailChimp.api.get.calls.count()).toBe(1)
        expect(mailChimp.api.put.calls.count()).toBe(1)
        args = mailChimp.api.put.calls.argsFor(0)
        expect(args[1].status).toBe('subscribed')
        done()
      
      
