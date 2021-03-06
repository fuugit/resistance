class Game extends Room
    constructor: (@id, @gameType, @lobby, @db) ->
        super
            'leave': @onLeave
            'chat': @onChat
            'allChat': @onAllChat
            'choose': @onChoose
            'choosePlayers': @onChoosePlayers
            'chooseTakeCard': @onChooseTakeCard
            'refresh': @onRefresh
        @nextId = 1
        @leader = 0
        @activePlayers = []
        @spies = []
        @questions = []
        @status = ''
        @gameStarted = false
        @gameFinished = false
        @log = []
        @cards = []
        @mission = 1
        @round = 1
        @score = []
        @guns = []
        @cardName =
            KeepingCloseEye: 'KEEPING A CLOSE EYE ON YOU'
            EstablishConfidence: 'ESTABLISH CONFIDENCE'
            StrongLeader: 'STRONG LEADER'
            Overheard: 'OVERHEARD CONVERSATION'
            NoConfidence: 'NO CONFIDENCE'
            InTheSpotlight: 'IN THE SPOTLIGHT'
            OpenUp: 'OPEN UP'
            TakeResponsibility: 'TAKE RESPONSIBILITY'
            OpinionMaker: 'OPINION MAKER'
        @removedPlayerIds = []
        @votelog =
            rounds: [0, 0, 0, 0, 0]
            leader: []
            approve: []
            reject: []
            onteam: []
    
    onRequest: (player, request) ->
        if @dbId? and request.cmd not in ['chat', 'allChat']
            @db.updateGame @dbId, ++@nextId, player.id, JSON.stringify(request), (err) ->
                console.log err if err?
        super
        
    onPlayerJoin: (player) ->
        super
        for p in @activePlayers when p.id is player.id
            p.__proto__ = player
        @onRefresh(player)
        if @players.length is 1 then @addActivePlayer(player) else @askToJoinGame(player)
        
    onRefresh: (player) ->
        player.send 'join'            
        @sendPlayers player
        player.send 'status', { msg:@status }
        player.send('gamelog', log) for log in @log
        player.send('+card', { player:card.player.id, card:card.card }) for card in @cards
        player.send 'scoreboard', @getScoreboard() if @gameStarted
        player.send 'leader', { player:@activePlayers[@leader].id } if @activePlayers.length > 0
        player.send(q.question.cmd, q.question) for q in @questions when q.player.id is player.id
        player.send 'gameover' if @gameFinished
        player.send 'guns', { players:@guns }
        player.send 'votelog', @votelog
    
    onPlayerLeave: (player) ->
        super

        @cancelQuestions([player]) if not @gameStarted
                         
        if player.id in @activePlayers.map((p)->p.id)
            if not @gameStarted
                @activePlayers.removeIf (p)->p.id is player.id
                @onPlayersChanged()
                
            currentPlayers = (p for p in @activePlayers when @players.some (i)->i.id is p.id)
            if currentPlayers.length is 0
                p.setRoom(@lobby) for p in @players[..]
                
        if @players.length is 0
            @lobby.onGameEnd(this)
            @endRoom()
                
        player.send 'leave'

    getLobbyStatus: ->
        status = 'Waiting'
        status = 'Running' if @gameStarted
        status = 'Finished' if @gameFinished
        "#{status} (#{@activePlayers.length} / 10)"
        
#-----------------------------------------------------------------------------    
# Handlers for user input
#-----------------------------------------------------------------------------
        
    onChat: (player, request) ->
        for p in @players
            p.send 'chat', { player:player.name, msg:request.msg }
            
    onAllChat: (player, request) ->
        @lobby.onAllChat(player, request)
            
    onLeave: (player, request) ->
        player.setRoom(@lobby)
        
    onChoose: (player, request) ->
        question = @findQuestion player, request
        return if not question?
        throw "Invalid response" if request.choice not in question.question.choices
        @answerQuestion question, request.choice
        
    onChoosePlayers: (player, request) ->
        question = @findQuestion player, request
        return if not question?
        if not question.question.canCancel or request.choice.length > 0
            throw "Incorrect number of players" if request.choice.length isnt question.question.n
        if question.question.players?
            for playerId in request.choice
                throw "Invalid player" if playerId not in question.question.players 
        @answerQuestion question, (@findPlayer(playerId) for playerId in request.choice)
        
    onChooseTakeCard: (player, request) ->
        question = @findQuestion player, request
        return if not question?
        @answerQuestion question, { card:request.choice.card, player:@findPlayer(request.choice.player) }

#-----------------------------------------------------------------------------    
# Primary game logic
#-----------------------------------------------------------------------------    
    
    addActivePlayer: (player) ->
        playerShim = 
            thisGame: this
            send: -> @__proto__.send.apply(this, arguments) if @room is @thisGame
            sendMsg: -> @__proto__.sendMsg.apply(this, arguments) if @room is @thisGame
        playerShim.__proto__ = player
        @activePlayers.push playerShim
        @onPlayersChanged()
        
    askToJoinGame: (player) ->
        return if @gameStarted or player.id in @removedPlayerIds
        @askOne player,
            cmd: 'choose'
            msg: 'Click "join" to join the game.'
            choices: ['Join']
            (response) =>
                if @gameStarted
                    player.sendMsg 'This game has already started.'
                else if @activePlayers.length >= 10
                    player.sendMsg 'This game is currently full.'
                    @askToJoinGame player
                else
                    @addActivePlayer player
    
    askToStartGame: ->
        return if @gameStarted or @activePlayers.length is 0
        gameController = @activePlayers[0]
        
        if @activePlayers.length < 5
            @setStatus 'Waiting for more players ...'
        else
            @setStatus "Waiting for #{gameController} to start the game ..."
        
        if @questions.every((i)->i.player isnt gameController)
            @askOne gameController,
                cmd: 'choose'
                msg: 'Press OK to start game.'
                choices: ['OK', 'Remove player']
                (response) =>
                    switch response.choice
                        when 'OK'
                            if @activePlayers.length < 5
                                gameController.sendMsg 'This game needs 5 or more players to start.'
                                @askToStartGame()
                            else 
                                @startGame()
                        when 'Remove player'
                            @askToRemovePlayer(gameController)

    askToRemovePlayer: (gameController) ->
        @askOne gameController,
            cmd: 'choosePlayers'
            n: 1
            msg: 'Choose which player to remove from game.'
            canCancel: true
            (response) =>
                if response.choice.length > 0 and response.choice[0] isnt gameController
                    @removedPlayerIds.push(response.choice[0].id)
                    @activePlayers = (p for p in @activePlayers when p isnt response.choice[0])
                    response.choice[0].sendMsg 'You have been removed from the game.'
                    @onPlayersChanged()
                @askToStartGame()

    startGame: ->
        @cancelQuestions @everyoneExcept(@activePlayers, @players)
        
        @lobby.onGameUpdate(this)
        @activePlayers.shuffle()
        state = @getInitialState()

        @spies = state.spies
        @leader = state.leader
        @deck = state.deck
        @merlin = @findPlayer(state.merlin) if state.merlin?
        @assassin = @findPlayer(state.assassin) if state.assassin?
        @gameStarted = true
        @onPlayersChanged()
        @missionTeamSizes = [
            [2, 3, 2, 3, 3]
            [2, 3, 4, 3, 4]
            [2, 3, 3, 4, 4]
            [3, 4, 4, 5, 5]
            [3, 4, 4, 5, 5]
            [3, 4, 4, 5, 5]][@activePlayers.length - 5]
        @failuresRequired = [
            [1, 1, 1, 1, 1],
            [1, 1, 1, 1, 1],
            [1, 1, 1, 2, 1],
            [1, 1, 1, 2, 1],
            [1, 1, 1, 2, 1],
            [1, 1, 1, 2, 1]][@activePlayers.length - 5]
            
        for p in @activePlayers
            startMsg = (if p in @spies then "You are a SPY!" else "You are RESISTANCE! There are #{@spies.length} spies in this game.")
            if p is @assassin
                startMsg = "You are the assassin. " + startMsg
            if p is @merlin
                startMsg = "You are Merlin. " + startMsg 
            p.sendMsg startMsg
                
        dbState = 
            deck: @deck
            leader: @leader
            merlin: state.merlin
            assassin:state.assassin
        @db.createGame JSON.stringify(dbState), @gameType, @activePlayers, @spies,
            (err, result) => 
                @dbId = result
                @nextRound()
                p.flush() for p in @players
          
    nextRound: ->
        return @spiesWin() if @round > 5
        @leader = (@leader + 1) % @activePlayers.length
        @sendAll 'scoreboard', @getScoreboard()
        @sendAll 'leader', { player:@activePlayers[@leader].id }
        @setGuns []
        @gameLog "#{@activePlayers[@leader]} is the mission leader."
        
        @ask 'deciding whether they want to use STRONG LEADER ...',
            @makeQuestions @everyoneExcept([@activePlayers[@leader]], @whoeverHas('StrongLeader')),
                cmd: 'choose'
                msg: 'Do you want to use STRONG LEADER?'
                choices: ['Yes', 'No']
                (response, doneCb) =>
                    return doneCb() if response.choice is 'No'
                    strongLeader = response.player
                    @leader = @activePlayers.indexOf(strongLeader)
                    @sendAllMsgAndGameLog "#{strongLeader} used STRONG LEADER."
                    @subCard strongLeader, 'StrongLeader'
                    @sendAll 'leader', { player:strongLeader.id }
                    @cancelQuestions()
                    @distributeCards()
            => @distributeCards()
                    
    distributeCards: ->
        @votelog.rounds[@mission - 1] = @round
        @votelog.leader.push @activePlayers[@leader].id
        @votelog.approve.push []
        @votelog.reject.push []
        @votelog.onteam.push []
        
        return @askLeaderForTeam() if @round isnt 1 or @gameType isnt ORIGINAL_GAMETYPE
        cardsRequired = Math.floor((@activePlayers.length - 3) / 2)
        cards = (@deck.shift() for i in [0 ... cardsRequired])
        leader = @activePlayers[@leader]
        
        questionText = (card) =>
            if card is 'EstablishConfidence'
                "You have ESTABLISH CONFIDENCE. Choose who to reveal your identity to."
            else
                "Choose a player to give #{@cardName[card]} to."
        
        @ask "deciding who to give #{@nameList (@cardName[card] for card in cards)} to ...",
            for card in cards
                do (card) =>
                    player: leader,
                    question:
                        cmd: 'choosePlayers'
                        msg: questionText(card)
                        n: 1,
                        players: @getIds @everyoneExcept [leader]
                    cb: (response, doneCb) => @distributeCard(leader, card, response.choice[0], doneCb)
            => @askLeaderForTeam()
        
    distributeCard: (player, card, recipient, doneCb) ->
        if card isnt 'EstablishConfidence'
            @sendAllMsgAndGameLog "#{player} gave #{@cardName[card]} to #{recipient}.", [player]
    
        showIdentityTo = (src, dest) =>
            dest.sendMsg "#{src} is #{if src in @spies then 'a SPY' else 'RESISTANCE'}!"
            doneCb()
            
        askChooseTakeCard = =>
            if @cards.filter((c) -> c.player.id isnt recipient.id).length is 0
                @sendAllMsgAndGameLog "TAKE RESPONSIBILITY was not used, since no other player has any cards."
                return doneCb()
                
            playerIds = @getIds @everyoneExcept [recipient]
            @askOne recipient,
                cmd: 'chooseTakeCard'
                msg: 'Take a card from another player.'
                players: playerIds
                (response) =>
                    invalidPlayer = response.choice.player.id not in playerIds
                    invalidCard = not @cards.some (c) -> c.card is response.choice.card and c.player is response.choice.player
                    if invalidPlayer or invalidCard
                        recipient.sendMsg 'That is not a valid card. Try again.'
                        askChooseTakeCard()
                    else
                        @sendAllMsgAndGameLog "#{recipient} used TAKE RESPONSIBILITY to take #{@cardName[response.choice.card]} from #{response.choice.player}.", [recipient]
                        @subCard response.choice.player, response.choice.card 
                        @addCard recipient, response.choice.card
                        doneCb()

        switch card
            when 'Overheard'
                @askOne recipient,
                    cmd: 'choosePlayers'
                    msg: 'Choose who you want to use OVERHEARD CONVERSATION on.'
                    n: 1
                    players: @getIds @neighboringPlayers recipient
                    (response) =>
                        @sendAllMsgAndGameLog "#{recipient} used OVERHEARD CONVERSATION to learn the identity of #{response.choice[0]}.", [recipient]
                        showIdentityTo response.choice[0], recipient
            when 'OpenUp'
                @askOne recipient,
                    cmd: 'choosePlayers'
                    msg: 'Choose who you want to reveal your identity to.'
                    n: 1, 
                    players: @getIds @everyoneExcept [recipient]
                    (response) => 
                        @sendAllMsgAndGameLog "#{recipient} used OPEN UP to show their identity to #{response.choice[0]}."
                        showIdentityTo recipient, response.choice[0]
            when 'EstablishConfidence'
                @sendAllMsgAndGameLog "#{player} used ESTABLISH CONFIDENCE to show their identity to #{recipient}."
                showIdentityTo player, recipient
            when 'TakeResponsibility'
                askChooseTakeCard()
            else 
                @addCard recipient, card
                doneCb()

    askLeaderForTeam: ->
        @ask 'choosing the mission team ...',
            @makeQuestions [@activePlayers[@leader]],
                cmd: 'choosePlayers'
                msg: "Choose #{@missionTeamSizes[@mission - 1]} players for your mission team.", 
                n: @missionTeamSizes[@mission - 1]
                (response, doneCb) =>
                    context = 
                        msg: "#{response.player} chose mission team: #{@playerNameList(response.choice)}."
                        team: response.choice
                        votes: []
                    @votelog.onteam.pop()
                    @votelog.onteam.push (p.id for p in response.choice)
                    @gameLog context.msg
                    @setGuns response.choice.map (i) -> i.id
                    @sendAll '-vote'
                    opinionMakers = @whoeverHas('OpinionMaker')
                    @askForTeamApproval opinionMakers, context, (context) =>
                        @askForTeamApproval @everyoneExcept(opinionMakers), context, (context) =>
                            @checkTeamApproval(context)
                    doneCb()
                
    askForTeamApproval: (players, context, cb) ->
        responses = []
        @ask 'voting on the mission team ...',
            @makeQuestions players,
                cmd: 'choose'
                msg: context.msg
                choices: ['Approve', 'Reject']
                (response, doneCb) => responses.push(response); doneCb()
            =>
                for response in responses
                    @votelog.approve[@votelog.approve.length - 1].push(response.player.id) if response.choice is 'Approve'
                    @votelog.reject[@votelog.reject.length - 1].push(response.player.id) if response.choice is 'Reject'
                    @sendAll '+vote', { player:response.player.id, vote:response.choice }
                context.votes = context.votes.concat(responses)
                cb(context)

    checkTeamApproval: (context) ->
        playerIdsApproving = (vote.player.id for vote in context.votes when vote.choice is 'Approve')
        playerIdsOnTeam = (player.id for player in context.team)
        
        approvalList = (onTeam, approving) =>
            @playerNameList (player for player in @activePlayers when (player.id in playerIdsApproving) is approving and (player.id in playerIdsOnTeam) is onTeam)
            
        @gameLog ''
        @gameLog "Team members approving: #{approvalList(true, true)}"
        @gameLog "Team members rejecting: #{approvalList(true, false)}"
        @gameLog "Non-team members approving: #{approvalList(false, true)}"
        @gameLog "Non-team members rejecting: #{approvalList(false, false)}"
        @gameLog ''
        
        if playerIdsApproving.length > @activePlayers.length / 2
            @sendAllMsgAndGameLog "The mission team is APPROVED."
            @askNoConfidencesToVetoTeam(context)
        else
            #@sendAllMsgAndGameLog "The mission team is REJECTED."
            @round++
            @nextRound()

    askNoConfidencesToVetoTeam: (context) ->
        @ask 'deciding whether to use NO CONFIDENCE ...',
            @makeQuestions @whoeverHas('NoConfidence'),
                cmd: 'choose'
                msg: 'Do you want to use NO CONFIDENCE?'
                choices: ['Yes', 'No']
                (response, doneCb) =>                    
                    return doneCb() if response.choice is 'No'
                    @sendAllMsgAndGameLog "#{response.player} used NO CONFIDENCE."
                    @subCard response.player, 'NoConfidence'
                    @cancelQuestions()
                    @round++
                    @nextRound() 
            => @askInTheSpotlight(context)

    askInTheSpotlight: (context) ->
        @ask 'deciding whether to use IN THE SPOTLIGHT ...',
            @makeQuestions @whoeverHas('InTheSpotlight'),
                cmd: 'choose'
                msg: 'Do you want to use IN THE SPOTLIGHT?'
                choices: ['Yes', 'No']
                (response, doneCb) =>
                    return doneCb() if response.choice is 'No'
                    @askOne response.player,
                        cmd: 'choosePlayers'
                        msg: 'Choose who you want to use IN THE SPOTLIGHT on.'
                        n: 1
                        players: @getIds context.team
                        (response) =>
                            @sendAllMsgAndGameLog "#{response.player} used IN THE SPOTLIGHT on #{response.choice[0]}"
                            @subCard response.player, 'InTheSpotlight'
                            context.spotlight = response.choice[0]
                            doneCb()
            => @askMissionMembersForVote(context)
                
    askMissionMembersForVote: (context) ->
        context.votes = []
        @ask 'voting on the success of the mission ...',
            @makeQuestions context.team,
                cmd: 'choose'
                msg: 'Do you want the mission to succeed or fail?'
                choices: ['Succeed', 'Fail']
                (response, doneCb) => context.votes.push(response); doneCb()
            =>
                for response in context.votes when context.spotlight is response.player
                    @sendAllMsgAndGameLog "#{context.spotlight} voted for #{if response.choice is 'Succeed' then 'SUCCESS' else 'FAILURE'}."
                @askKeepingCloseEyes(context)
                
    askKeepingCloseEyes: (context) ->
        validPlayers = context.team[..]
        pickPlayer = null
                            
        pickPlayer = (player, doneCb) =>
            @askOne player,
                cmd: 'choosePlayers'
                msg: 'Choose who you want to use KEEPING A CLOSE EYE ON YOU on.'
                n: 1
                players: @getIds validPlayers
                canCancel: true
                (response) =>
                    return doneCb() if response.choice.length is 0
                    if response.choice[0] not in validPlayers
                        player.sendMsg "Someone has already played KEEPING A CLOSE EYE ON YOU on #{response.choice[0]}."
                        return pickPlayer(player, doneCb)
                    choice = response.choice[0]
                    validPlayers.remove choice
                    @sendAllMsgAndGameLog "#{response.player} played KEEPING A CLOSE EYE ON YOU on #{choice}."
                    @subCard response.player, 'KeepingCloseEye'
                    for vote in context.votes when vote.player is choice
                        @askOne player,
                            cmd: 'choose'
                            msg: "#{choice} voted for #{if vote.choice is 'Succeed' then 'SUCCESS' else 'FAILURE'}."
                            choices: ['OK']
                            (response) => doneCb()
                                
        @ask 'deciding whether to use KEEPING A CLOSE EYE ON YOU ...',
            @makeQuestions @whoeverHas('KeepingCloseEye'),
                cmd: 'choose'
                msg: 'Do you want to use KEEPING A CLOSE EYE ON YOU?'
                choices: ['Yes', 'No']
                (response, doneCb) =>
                    return doneCb() if response.choice is 'No'
                    pickPlayer(response.player, doneCb)
            => @checkMissionSuccess(context)  
                      
    checkMissionSuccess: (context) ->
        nPlayers = [
            "No one",
            "One player",
            "Two players",
            "Three players",
            "Four players"
        ]
    
        requiredFailures = @failuresRequired[@mission - 1]
        actualFailures = (vote for vote in context.votes when vote.choice isnt 'Succeed').length
        success = actualFailures < requiredFailures
        @sendAllMsgAndGameLog "The mission #{if success then 'SUCCEEDED' else 'FAILED'}. #{nPlayers[actualFailures]} voted for failure."
        
        @score.push success
        @sendAll 'scoreboard', @getScoreboard()
        if (score for score in @score when not score).length is 3
            @sendAllMsg("#{@merlin} was Merlin.") if @merlin?
            return @spiesWin()
        return @askToAssassinateMerlin() if (score for score in @score when score).length is 3
        @round = 1
        @mission++
        @nextRound()

    askToAssassinateMerlin: ->
        return @resistanceWins() if @gameType isnt AVALON_GAMETYPE
        @ask 'choosing a player to assassinate ...',
            @makeQuestions [@assassin],
                cmd: 'choosePlayers'
                msg: 'Choose a player to assassinate.'
                n: 1
                players: @getIds @everyoneExcept @spies
                (response, doneCb) =>
                    @sendAllMsgAndGameLog "#{@assassin} chose to assassinate #{response.choice[0]}."
                    if response.choice[0] is @merlin
                        @sendAllMsgAndGameLog "#{@assassin} guessed RIGHT. #{response.choice[0]} was Merlin!"
                        @spiesWin()
                    else
                        @sendAllMsgAndGameLog "#{@assassin} guessed WRONG. #{@merlin} was Merlin, not #{response.choice[0]}!"
                        @resistanceWins()
                    doneCb()
        
    spiesWin: ->
        @gameOver(true)

    resistanceWins: ->
        @gameOver(false)
        
    gameOver: (spiesWin) ->
        @gameFinished = true
        @sendAll 'gameover'
        @sendPlayers(p) for p in @players
        @setStatus (if spiesWin then 'The spies win!' else 'The resistance wins!')
        @lobby.onGameUpdate(this)
        @db.finishGame @dbId, spiesWin, ->

#-----------------------------------------------------------------------------    
# Helper functions
#-----------------------------------------------------------------------------    
   
    addCard: (player, card) ->
        @sendAll '+card', {player:player.id, card:card}
        @cards.push {player:player, card:card}
        
    subCard: (player, card) ->
        @sendAll '-card', {player:player.id, card:card}
        for c,idx in @cards when c.player is player and c.card is card
            return @cards.splice(idx, 1)
            
    playerNameList: (players) ->
        @nameList (player.name for player in players)
    
    nameList: (names) ->
        ans = ''
        for i in [0 ... names.length]
            ans += ',' if i > 0 and names.length > 2
            ans += ' and' if i > 0 and i is names.length - 1
            ans += ' ' if i > 0
            ans += names[i]
        return ans
    
    sendAll: (msg, action, exempt = []) ->
        exemptIds = exempt.map (p) -> p.id
        player.send(msg, action) for player in @players when player.id not in exemptIds
        
    sendAllMsg: (msg, exempt = []) ->
        @sendAll 'msg', {msg:msg}, exempt
    
    sendAllMsgAndGameLog: (msg, exempt = []) ->
        @sendAllMsg msg, exempt
        @gameLog msg
            
    gameLog: (msg) ->
        log = { mission:@mission, round:@round, msg:msg }
        @sendAll 'gamelog', log 
        @log.push log
    
    neighboringPlayers: (player) ->
        ans = []
        prevPlayer = @activePlayers[@activePlayers.length - 1]
        for curPlayer in @activePlayers
            ans.push(prevPlayer) if curPlayer is player
            ans.push(curPlayer) if prevPlayer is player
            prevPlayer = curPlayer
        return ans
        
    everyoneExcept: (exempt, group = @activePlayers) ->
        return group if exempt.length is 0
        exemptPlayerIds = @getIds exempt
        player for player in group when player.id not in exemptPlayerIds
        
    getIds: (players) ->
        player.id for player in players
    
    whoeverHas: (cardName) ->
        players = (card.player for card in @cards when card.card is cardName)
        player for player in @activePlayers when player in players

    onPlayersChanged: ->
        @lobby.onGameUpdate(this)
        @sendPlayers(p) for p in @players
        @askToStartGame()
            
    sendPlayers: (player) ->
        amSpy = @spies.some (i) -> i.id is player.id
        amMerlin = @merlin? and @merlin.id is player.id
        response = (for p in @activePlayers 
            {
                isSpy: (amSpy or amMerlin or @gameFinished) and p in @spies
                id: p.id
                name: p.name
            })
        player.send 'players', { players:response, amSpy:amSpy }
                
    askOne: (player, cmd, cb) ->
        question = JSON.parse(JSON.stringify(cmd))
        question.choiceId = @nextId++
        @questions.push { player:player, question:question, cb:cb }
        player.send question.cmd, question

    ask: (status, questions, cb = ->) ->
        return cb() if questions.length is 0
        players = questions.map (q) -> q.player

        showStatus = =>
            uniquePlayers = (p for p in @activePlayers when p in players)
            isAre = (if uniquePlayers.length is 1 then 'is' else 'are')
            @setStatus "#{@nameList(uniquePlayers)} #{isAre} #{status}"

        showStatus()
        for q in questions
            do (q) =>
                @askOne q.player, q.question, (response) => q.cb(response, =>
                    players.remove q.player
                    return cb() if players.length is 0
                    showStatus())
        
    makeQuestions: (players, question, cb) ->
        for p in players
            player: p
            question: question
            cb: cb
    
    findQuestion: (player, request) ->
        for q in @questions when q.question.choiceId is request.choiceId
            throw "Incorrect cmd" if q.question.cmd isnt request.cmd
            throw "Incorrect responding player" if player.id isnt q.player.id
            return q
        return null

    findPlayer: (playerId) ->
        for p in @activePlayers when p.id is playerId
            return p
        throw "Invalid player"
        
    answerQuestion: (question, choice) ->
        question.choice = choice
        @questions.remove question
        question.cb(question)
        
    cancelQuestions: (who = @activePlayers) ->
        playerIds = @getIds(who)
        for q in @questions when q.player.id in playerIds
            q.player.send 'cancelChoose', { choiceId:q.question.choiceId }
        @questions = (q for q in @questions when q.player.id not in playerIds)
            
    setStatus: (msg) ->
        @status = msg
        p.send('status', {msg:msg}) for p in @players

    getInitialState: ->
        spies = []
        spiesRequired = Math.floor((@activePlayers.length - 1) / 3) + 1
        for i in [0 ... @activePlayers.length]
            if Math.random() < spiesRequired / (@activePlayers.length - i)
                spies.push @activePlayers[i]
                --spiesRequired

        initialOriginalState = =>
            deck = [
                "KeepingCloseEye"
                "KeepingCloseEye"
                "NoConfidence" 
                "OpinionMaker"
                "TakeResponsibility"
                "StrongLeader"
                "StrongLeader"
            ]
            if @activePlayers.length > 6
                deck = deck.concat [
                    "NoConfidence"
                    "NoConfidence"
                    "OpenUp"
                    "OpinionMaker"
                    "Overheard"
                    "Overheard"
                    "InTheSpotlight"
                    "EstablishConfidence"
                ]
            deck.shuffle()        
            return {
                spies: spies
                deck: deck
                leader: Math.floor(Math.random() * @activePlayers.length)
            }
                
        initialAvalonState = =>
            resistance = @everyoneExcept spies
            return {
                merlin: resistance[Math.floor(Math.random() * resistance.length)].id
                assassin: spies[Math.floor(Math.random() * spies.length)].id
                spies: spies
                leader: Math.floor(Math.random() * @activePlayers.length)
            }
            
        initialBasicState = =>
            return {
                spies: spies
                leader: Math.floor(Math.random() * @activePlayers.length)
            }

        return initialOriginalState() if @gameType is ORIGINAL_GAMETYPE
        return initialAvalonState() if @gameType is AVALON_GAMETYPE
        return initialBasicState() if @gameType is BASIC_GAMETYPE
        
    getScoreboard: ->
        return {
            mission: @mission
            round: @round
            score: @score[..]
            missionTeamSizes: @missionTeamSizes
            failuresRequired: @failuresRequired
        }

    setGuns: (guns) ->
        @guns = guns
        @sendAll 'guns', { players: guns }