//
// This source file is part of the My Heart Counts iOS application based on the Stanford Spezi Template Application project
//
// SPDX-FileCopyrightText: 2026 Stanford University
//
// SPDX-License-Identifier: MIT
//

import Foundation
import HealthKit


extension HKWorkoutActivityType {
    /// User-displayable localized title for the workout type
    var displayTitle: LocalizedStringResource {
        switch self {
        case .americanFootball:
            LocalizedStringResource("WORKOUT_TYPE_AMERICAN_FOOTBALL", defaultValue: "American Football")
        case .archery:
            LocalizedStringResource("WORKOUT_TYPE_ARCHERY", defaultValue: "Archery")
        case .australianFootball:
            LocalizedStringResource("WORKOUT_TYPE_AUSTRALIAN_FOOTBALL", defaultValue: "Australian Football")
        case .badminton:
            LocalizedStringResource("WORKOUT_TYPE_BADMINTON", defaultValue: "Badminton")
        case .baseball:
            LocalizedStringResource("WORKOUT_TYPE_BASEBALL", defaultValue: "Baseball")
        case .basketball:
            LocalizedStringResource("WORKOUT_TYPE_BASKETBALL", defaultValue: "Basketball")
        case .bowling:
            LocalizedStringResource("WORKOUT_TYPE_BOWLING", defaultValue: "Bowling")
        case .boxing:
            LocalizedStringResource("WORKOUT_TYPE_BOXING", defaultValue: "Boxing")
        case .climbing:
            LocalizedStringResource("WORKOUT_TYPE_CLIMBING", defaultValue: "Climbing")
        case .cricket:
            LocalizedStringResource("WORKOUT_TYPE_CRICKET", defaultValue: "Cricket")
        case .crossTraining:
            LocalizedStringResource("WORKOUT_TYPE_CROSS_TRAINING", defaultValue: "Cross Training")
        case .curling:
            LocalizedStringResource("WORKOUT_TYPE_CURLING", defaultValue: "Curling")
        case .cycling:
            LocalizedStringResource("WORKOUT_TYPE_CYCLING", defaultValue: "Cycling")
        case .elliptical:
            LocalizedStringResource("WORKOUT_TYPE_ELLIPTICAL", defaultValue: "Elliptical")
        case .equestrianSports:
            LocalizedStringResource("WORKOUT_TYPE_EQUESTRIAN_SPORTS", defaultValue: "Equestrian Sports")
        case .fencing:
            LocalizedStringResource("WORKOUT_TYPE_FENCING", defaultValue: "Fencing")
        case .fishing:
            LocalizedStringResource("WORKOUT_TYPE_FISHING", defaultValue: "Fishing")
        case .functionalStrengthTraining:
            LocalizedStringResource("WORKOUT_TYPE_FUNCTIONAL_STRENGTH_TRAINING", defaultValue: "Functional Strength Training")
        case .golf:
            LocalizedStringResource("WORKOUT_TYPE_GOLF", defaultValue: "Golf")
        case .gymnastics:
            LocalizedStringResource("WORKOUT_TYPE_GYMNASTICS", defaultValue: "Gymnastics")
        case .handball:
            LocalizedStringResource("WORKOUT_TYPE_HANDBALL", defaultValue: "Handball")
        case .hiking:
            LocalizedStringResource("WORKOUT_TYPE_HIKING", defaultValue: "Hiking")
        case .hockey:
            LocalizedStringResource("WORKOUT_TYPE_HOCKEY", defaultValue: "Hockey")
        case .hunting:
            LocalizedStringResource("WORKOUT_TYPE_HUNTING", defaultValue: "Hunting")
        case .lacrosse:
            LocalizedStringResource("WORKOUT_TYPE_LACROSSE", defaultValue: "Lacrosse")
        case .martialArts:
            LocalizedStringResource("WORKOUT_TYPE_MARTIAL_ARTS", defaultValue: "Martial Arts")
        case .mindAndBody:
            LocalizedStringResource("WORKOUT_TYPE_MIND_AND_BODY", defaultValue: "Mind and Body")
        case .paddleSports:
            LocalizedStringResource("WORKOUT_TYPE_PADDLE_SPORTS", defaultValue: "Paddle Sports")
        case .play:
            LocalizedStringResource("WORKOUT_TYPE_PLAY", defaultValue: "Play")
        case .preparationAndRecovery:
            LocalizedStringResource("WORKOUT_TYPE_PREPARATION_AND_RECOVERY", defaultValue: "Preparation and Recovery")
        case .racquetball:
            LocalizedStringResource("WORKOUT_TYPE_RACQUETBALL", defaultValue: "Racquetball")
        case .rowing:
            LocalizedStringResource("WORKOUT_TYPE_ROWING", defaultValue: "Rowing")
        case .rugby:
            LocalizedStringResource("WORKOUT_TYPE_RUGBY", defaultValue: "Rugby")
        case .running:
            LocalizedStringResource("WORKOUT_TYPE_RUNNING", defaultValue: "Running")
        case .sailing:
            LocalizedStringResource("WORKOUT_TYPE_SAILING", defaultValue: "Sailing")
        case .skatingSports:
            LocalizedStringResource("WORKOUT_TYPE_SKATING_SPORTS", defaultValue: "Skating Sports")
        case .snowSports:
            LocalizedStringResource("WORKOUT_TYPE_SNOW_SPORTS", defaultValue: "Snow Sports")
        case .soccer:
            LocalizedStringResource("WORKOUT_TYPE_SOCCER", defaultValue: "Soccer")
        case .softball:
            LocalizedStringResource("WORKOUT_TYPE_SOFTBALL", defaultValue: "Softball")
        case .squash:
            LocalizedStringResource("WORKOUT_TYPE_SQUASH", defaultValue: "Squash")
        case .stairClimbing:
            LocalizedStringResource("WORKOUT_TYPE_STAIR_CLIMBING", defaultValue: "Stair Climbing")
        case .surfingSports:
            LocalizedStringResource("WORKOUT_TYPE_SURFING_SPORTS", defaultValue: "Surfing Sports")
        case .swimming:
            LocalizedStringResource("WORKOUT_TYPE_SWIMMING", defaultValue: "Swimming")
        case .tableTennis:
            LocalizedStringResource("WORKOUT_TYPE_TABLE_TENNIS", defaultValue: "Table Tennis")
        case .tennis:
            LocalizedStringResource("WORKOUT_TYPE_TENNIS", defaultValue: "Tennis")
        case .trackAndField:
            LocalizedStringResource("WORKOUT_TYPE_TRACK_AND_FIELD", defaultValue: "Track and Field")
        case .traditionalStrengthTraining:
            LocalizedStringResource("WORKOUT_TYPE_TRADITIONAL_STRENGTH_TRAINING", defaultValue: "Traditional Strength Training")
        case .volleyball:
            LocalizedStringResource("WORKOUT_TYPE_VOLLEYBALL", defaultValue: "Volleyball")
        case .walking:
            LocalizedStringResource("WORKOUT_TYPE_WALKING", defaultValue: "Walking")
        case .waterFitness:
            LocalizedStringResource("WORKOUT_TYPE_WATER_FITNESS", defaultValue: "Water Fitness")
        case .waterPolo:
            LocalizedStringResource("WORKOUT_TYPE_WATER_POLO", defaultValue: "Water Polo")
        case .waterSports:
            LocalizedStringResource("WORKOUT_TYPE_WATER_SPORTS", defaultValue: "Water Sports")
        case .wrestling:
            LocalizedStringResource("WORKOUT_TYPE_WRESTLING", defaultValue: "Wrestling")
        case .yoga:
            LocalizedStringResource("WORKOUT_TYPE_YOGA", defaultValue: "Yoga")
        case .barre:
            LocalizedStringResource("WORKOUT_TYPE_BARRE", defaultValue: "Barre")
        case .coreTraining:
            LocalizedStringResource("WORKOUT_TYPE_CORE_TRAINING", defaultValue: "Core Training")
        case .crossCountrySkiing:
            LocalizedStringResource("WORKOUT_TYPE_CROSS_COUNTRY_SKIING", defaultValue: "Cross Country Skiing")
        case .downhillSkiing:
            LocalizedStringResource("WORKOUT_TYPE_DOWNHILL_SKIING", defaultValue: "Downhill Skiing")
        case .flexibility:
            LocalizedStringResource("WORKOUT_TYPE_FLEXIBILITY", defaultValue: "Flexibility")
        case .highIntensityIntervalTraining:
            LocalizedStringResource("WORKOUT_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING", defaultValue: "High Intensity Interval Training")
        case .jumpRope:
            LocalizedStringResource("WORKOUT_TYPE_JUMP_ROPE", defaultValue: "Jump Rope")
        case .kickboxing:
            LocalizedStringResource("WORKOUT_TYPE_KICKBOXING", defaultValue: "Kickboxing")
        case .pilates:
            LocalizedStringResource("WORKOUT_TYPE_PILATES", defaultValue: "Pilates")
        case .snowboarding:
            LocalizedStringResource("WORKOUT_TYPE_SNOWBOARDING", defaultValue: "Snowboarding")
        case .stairs:
            LocalizedStringResource("WORKOUT_TYPE_STAIRS", defaultValue: "Stairs")
        case .stepTraining:
            LocalizedStringResource("WORKOUT_TYPE_STEP_TRAINING", defaultValue: "Step Training")
        case .wheelchairWalkPace:
            LocalizedStringResource("WORKOUT_TYPE_WHEELCHAIR_WALK_PACE", defaultValue: "Wheelchair Walk Pace")
        case .wheelchairRunPace:
            LocalizedStringResource("WORKOUT_TYPE_WHEELCHAIR_RUN_PACE", defaultValue: "Wheelchair Run Pace")
        case .taiChi:
            LocalizedStringResource("WORKOUT_TYPE_TAI_CHI", defaultValue: "Tai Chi")
        case .mixedCardio:
            LocalizedStringResource("WORKOUT_TYPE_MIXED_CARDIO", defaultValue: "Mixed Cardio")
        case .handCycling:
            LocalizedStringResource("WORKOUT_TYPE_HAND_CYCLING", defaultValue: "Hand Cycling")
        case .discSports:
            LocalizedStringResource("WORKOUT_TYPE_DISC_SPORTS", defaultValue: "Disc Sports")
        case .fitnessGaming:
            LocalizedStringResource("WORKOUT_TYPE_FITNESS_GAMING", defaultValue: "Fitness Gaming")
        case .cardioDance:
            LocalizedStringResource("WORKOUT_TYPE_CARDIO_DANCE", defaultValue: "Cardio Dance")
        case .socialDance:
            LocalizedStringResource("WORKOUT_TYPE_SOCIAL_DANCE", defaultValue: "Social Dance")
        case .pickleball:
            LocalizedStringResource("WORKOUT_TYPE_PICKLEBALL", defaultValue: "Pickleball")
        case .cooldown:
            LocalizedStringResource("WORKOUT_TYPE_COOLDOWN", defaultValue: "Cooldown")
        case .swimBikeRun:
            LocalizedStringResource("WORKOUT_TYPE_SWIM_BIKE_RUN", defaultValue: "Swim Bike Run")
        case .transition:
            LocalizedStringResource("WORKOUT_TYPE_TRANSITION", defaultValue: "Transition")
        case .underwaterDiving:
            LocalizedStringResource("WORKOUT_TYPE_UNDERWATER_DIVING", defaultValue: "Underwater Diving")
        case .other:
            LocalizedStringResource("WORKOUT_TYPE_OTHER", defaultValue: "Other")
        case .dance:
            LocalizedStringResource("WORKOUT_TYPE_DANCE", defaultValue: "Dance")
        case .danceInspiredTraining:
            LocalizedStringResource("WORKOUT_TYPE_DANCE_INSPIRED_TRAINING", defaultValue: "Dance Inspired Training")
        case .mixedMetabolicCardioTraining:
            LocalizedStringResource("WORKOUT_TYPE_MIXED_METABOLIC_CARDIO_TRAINING", defaultValue: "Mixed Metabolic Cardio Training")
        @unknown default:
            LocalizedStringResource("WORKOUT_TYPE_UNKNOWN", defaultValue: "Workout")
        }
    }
}
